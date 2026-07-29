package ai.asleep.asleep_sdk_flutter

import ai.asleep.asleepsdk.Asleep
import ai.asleep.asleepsdk.data.AsleepConfig
import ai.asleep.asleepsdk.data.AverageReport
import ai.asleep.asleepsdk.data.Report
import ai.asleep.asleepsdk.data.Session
import ai.asleep.asleepsdk.data.SleepSession
import ai.asleep.asleepsdk.tracking.Reports
import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

internal object NativeSdkOwnerRegistry {
    private var owner: Any? = null

    @Synchronized
    fun claim(candidate: Any): Boolean {
        if (owner == null) {
            owner = candidate
        }
        return owner === candidate
    }

    @Synchronized
    fun isOwner(candidate: Any): Boolean = owner === candidate

    @Synchronized
    fun release(candidate: Any) {
        if (owner === candidate) {
            owner = null
        }
    }
}

class AsleepSdkFlutterPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private var hostApi: AndroidAsleepHostApi? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val events = AndroidEventsStreamHandler()
        val api = AndroidAsleepHostApi(binding.applicationContext, events)
        hostApi = api
        AsleepHostApi.setUp(binding.binaryMessenger, api)
        EventsStreamHandler.register(binding.binaryMessenger, events)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        AsleepHostApi.setUp(binding.binaryMessenger, null)
        hostApi?.detach()
        hostApi = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        hostApi?.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        hostApi?.activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean = hostApi?.onRequestPermissionsResult(requestCode) ?: false
}

private class AndroidEventsStreamHandler : EventsStreamHandler() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: PigeonEventSink<NativeEventMessage>? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<NativeEventMessage>) {
        this.sink = sink
    }

    override fun onCancel(p0: Any?) {
        sink = null
    }

    fun emit(type: String, payloadJson: String) {
        mainHandler.post {
            sink?.success(NativeEventMessage(type = type, payloadJson = payloadJson))
        }
    }

    fun detach() {
        mainHandler.post {
            sink?.endOfStream()
            sink = null
        }
    }
}

private class AndroidAsleepHostApi(
    private val context: Context,
    private val events: AndroidEventsStreamHandler,
) : AsleepHostApi {
    companion object {
        private const val PERMISSION_REQUEST_CODE = 41207
        private val TERMINAL_TRACKING_ERROR_CODES =
            setOf(
                11003,
                22000,
                22401,
                22409,
                22422,
                22500,
                23499,
                24000,
                24400,
                24401,
                24403,
                24404,
                24500,
            )
    }

    private val gson = Gson()
    private var asleepConfig: AsleepConfig? = null
    private var reports: Reports? = null
    private var loggingEnabled = false
    private var setupCallback: ((Result<Unit>) -> Unit)? = null
    private var configureCallback: ((Result<Unit>) -> Unit)? = null
    private var permissionCallback: ((Result<Boolean>) -> Unit)? = null
    private var setupInFlight = false
    private var configureInFlight = false
    private var detached = false
    var activity: Activity? = null

    override fun setup(message: SetupMessage, callback: (Result<Unit>) -> Unit) {
        if (!claimNativeSdk(callback)) return
        if (setupCallback != null || configureCallback != null) {
            callback(Result.failure(IllegalStateException("Setup or configuration is already in progress")))
            return
        }
        setupCallback = callback
        setupInFlight = true
        try {
            Asleep.setup(
                context = context,
                apiKey = message.apiKey,
                baseUrl = message.baseUrl,
                callbackUrl = message.callbackUrl,
                service = message.service ?: "SleepTracking",
                enableODA = message.enableOnDeviceAnalysis,
                asleepSetupListener = object : Asleep.AsleepSetupListener {
                    override fun onComplete() {
                        configureAfterSetup(message)
                    }

                    override fun onProgress(progress: Int) {
                        emit("onSetupInProgress", mapOf("progress" to progress))
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        emit("onSetupDidFail", errorPayload(errorCode, detail, "SETUP_FAILED"))
                        finishSetup(Result.failure(NativeSdkException(errorCode, detail)))
                    }
                },
            )
        } catch (error: Throwable) {
            finishSetup(Result.failure(error))
        }
    }

    override fun configure(message: ConfigurationMessage, callback: (Result<Unit>) -> Unit) {
        if (!claimNativeSdk(callback)) return
        if (setupCallback != null || configureCallback != null) {
            callback(Result.failure(IllegalStateException("Configuration is already in progress")))
            return
        }
        configureCallback = callback
        configureInFlight = true
        try {
            Asleep.initAsleepConfig(
                context = context,
                apiKey = message.apiKey,
                userId = message.userId,
                baseUrl = message.baseUrl,
                callbackUrl = message.callbackUrl,
                service = "SleepTracking",
                asleepConfigListener = object : Asleep.AsleepConfigListener {
                    override fun onSuccess(userId: String?, asleepConfig: AsleepConfig?) {
                        if (asleepConfig == null) {
                            finishConfigure(Result.failure(IllegalStateException("Native AsleepConfig is null")))
                            return
                        }
                        this@AndroidAsleepHostApi.asleepConfig = asleepConfig
                        reports = Asleep.createReports(asleepConfig)
                        emit("onUserJoined", mapOf("userId" to (userId ?: "")))
                        finishConfigure(Result.success(Unit))
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        emit(
                            "onUserJoinFailed",
                            errorPayload(errorCode, detail, "INITIALIZATION_FAILED"),
                        )
                        finishConfigure(Result.failure(NativeSdkException(errorCode, detail)))
                    }
                },
            )
        } catch (error: Throwable) {
            finishConfigure(Result.failure(error))
        }
    }

    override fun checkAndRestoreTracking(callback: (Result<RestoreMessage>) -> Unit) {
        if (!requireNativeSdkOwner(callback)) return
        try {
            val active = Asleep.isSleepTrackingAlive(context)
            if (active) {
                Asleep.connectSleepTracking(trackingListener())
            }
            callback(Result.success(RestoreMessage(hasActiveSession = active)))
        } catch (error: Throwable) {
            callback(Result.failure(error))
        }
    }

    override fun checkBatteryOptimization(
        callback: (Result<BatteryOptimizationMessage>) -> Unit,
    ) {
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val exempted =
                Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    powerManager.isIgnoringBatteryOptimizations(context.packageName)
            callback(
                Result.success(
                    BatteryOptimizationMessage(
                        exempted = exempted,
                        platform = "android",
                        message = if (exempted) null else "Battery optimization exemption is not granted",
                    ),
                ),
            )
        } catch (error: Throwable) {
            callback(Result.failure(error))
        }
    }

    override fun requestBatteryOptimizationExemption(callback: (Result<Boolean>) -> Unit) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                callback(Result.success(true))
                return
            }
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (powerManager.isIgnoringBatteryOptimizations(context.packageName)) {
                callback(Result.success(true))
                return
            }
            val intent =
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:${context.packageName}")
                }
            val currentActivity = activity
            if (currentActivity != null) {
                currentActivity.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            callback(Result.success(false))
        } catch (error: Throwable) {
            callback(Result.failure(error))
        }
    }

    override fun hasRequiredPermissions(callback: (Result<Boolean>) -> Unit) {
        callback(Result.success(hasRequiredPermissions()))
    }

    override fun requestRequiredPermissions(callback: (Result<Boolean>) -> Unit) {
        if (permissionsToRequest().all(::isPermissionGranted)) {
            callback(Result.success(true))
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            callback(Result.failure(IllegalStateException("An Activity is required to request permissions")))
            return
        }
        if (permissionCallback != null) {
            callback(Result.failure(IllegalStateException("A permission request is already in progress")))
            return
        }
        permissionCallback = callback
        ActivityCompat.requestPermissions(
            currentActivity,
            permissionsToRequest().toTypedArray(),
            PERMISSION_REQUEST_CODE,
        )
    }

    override fun startTracking(message: TrackingMessage, callback: (Result<Unit>) -> Unit) {
        if (!requireNativeSdkOwner(callback)) return
        val config = asleepConfig
        if (config == null) {
            callback(Result.failure(IllegalStateException("Asleep is not configured")))
            return
        }
        if (!hasRequiredPermissions()) {
            callback(Result.failure(SecurityException("Required microphone permissions are not granted")))
            return
        }
        try {
            val notification = message.androidNotification
            val iconId =
                notification?.icon
                    ?.let { name ->
                        context.resources.getIdentifier(name, "drawable", context.packageName)
                            .takeIf { it != 0 }
                            ?: context.resources.getIdentifier(name, "mipmap", context.packageName)
                                .takeIf { it != 0 }
                    }
                    ?: context.applicationInfo.icon
            Asleep.beginSleepTracking(
                asleepConfig = config,
                notificationClass = activity?.javaClass,
                notificationTitle = notification?.title ?: "Sleep Tracking",
                notificationText = notification?.text ?: "Monitoring your sleep",
                notificationIcon = iconId,
                asleepTrackingListener = trackingListener(),
            )
            callback(Result.success(Unit))
        } catch (error: Throwable) {
            callback(Result.failure(error))
        }
    }

    override fun resumeTracking(callback: (Result<Unit>) -> Unit) {
        callback(
            Result.failure(
                UnsupportedOperationException(
                    "Android tracking resumes through its foreground service; use checkAndRestoreTracking",
                ),
            ),
        )
    }

    override fun stopTracking(callback: (Result<Unit>) -> Unit) {
        if (!requireNativeSdkOwner(callback)) return
        try {
            Asleep.endSleepTracking()
            callback(Result.success(Unit))
        } catch (error: Throwable) {
            callback(Result.failure(error))
        }
    }

    override fun requestAnalysis(callback: (Result<AnalysisRequestMessage>) -> Unit) {
        if (!requireNativeSdkOwner(callback)) return
        try {
            Asleep.getCurrentSleepData(
                object : Asleep.AsleepSleepDataListener {
                    override fun onSleepDataReceived(session: Session) {
                        val resultJson = gson.toJson(session)
                        emitJson("onAnalysisResult", resultJson)
                        callback(
                            Result.success(
                                AnalysisRequestMessage(
                                    status = "completed",
                                    timestampMilliseconds = System.currentTimeMillis(),
                                    resultJson = resultJson,
                                ),
                            ),
                        )
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        callback(Result.failure(NativeSdkException(errorCode, detail)))
                    }
                },
            )
        } catch (error: Throwable) {
            callback(Result.failure(error))
        }
    }

    override fun getReport(sessionId: String, callback: (Result<String>) -> Unit) {
        if (!requireNativeSdkOwner(callback)) return
        val manager = requireReports(callback) ?: return
        manager.getReport(
            sessionId,
            object : Reports.ReportListener {
                override fun onSuccess(report: Report?) {
                    if (report == null) {
                        callback(Result.failure(IllegalStateException("Native report is null")))
                    } else {
                        callback(Result.success(gson.toJson(report)))
                    }
                }

                override fun onFail(errorCode: Int, detail: String) {
                    callback(Result.failure(NativeSdkException(errorCode, detail)))
                }
            },
        )
    }

    override fun getReportList(
        fromDate: String,
        toDate: String,
        callback: (Result<List<String>>) -> Unit,
    ) {
        if (!requireNativeSdkOwner(callback)) return
        val manager = requireReports(callback) ?: return
        manager.getReports(
            fromDate,
            toDate,
            "DESC",
            0,
            100,
            object : Reports.ReportsListener {
                override fun onSuccess(reports: List<SleepSession>?) {
                    callback(Result.success(reports.orEmpty().map(gson::toJson)))
                }

                override fun onFail(errorCode: Int, detail: String) {
                    callback(Result.failure(NativeSdkException(errorCode, detail)))
                }
            },
        )
    }

    override fun getAverageReport(
        fromDate: String,
        toDate: String,
        callback: (Result<String>) -> Unit,
    ) {
        if (!requireNativeSdkOwner(callback)) return
        val manager = requireReports(callback) ?: return
        manager.getAverageReport(
            fromDate,
            toDate,
            object : Reports.AverageReportListener {
                override fun onSuccess(averageReport: AverageReport?) {
                    if (averageReport == null) {
                        callback(Result.failure(IllegalStateException("Native average report is null")))
                    } else {
                        callback(Result.success(gson.toJson(averageReport)))
                    }
                }

                override fun onFail(errorCode: Int, detail: String) {
                    callback(Result.failure(NativeSdkException(errorCode, detail)))
                }
            },
        )
    }

    override fun deleteSession(sessionId: String, callback: (Result<Unit>) -> Unit) {
        if (!requireNativeSdkOwner(callback)) return
        val manager = requireReports(callback) ?: return
        manager.deleteReport(
            sessionId,
            object : Reports.DeleteReportListener {
                override fun onSuccess(sessionId: String?) {
                    callback(Result.success(Unit))
                }

                override fun onFail(errorCode: Int, detail: String) {
                    callback(Result.failure(NativeSdkException(errorCode, detail)))
                }
            },
        )
    }

    override fun setLoggingEnabled(enabled: Boolean, callback: (Result<Unit>) -> Unit) {
        loggingEnabled = enabled
        callback(Result.success(Unit))
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        permissionCallback?.invoke(Result.success(hasRequiredPermissions()))
        permissionCallback = null
        return true
    }

    fun detach() {
        detached = true
        setupCallback?.invoke(Result.failure(IllegalStateException("Flutter engine detached")))
        setupCallback = null
        configureCallback?.invoke(Result.failure(IllegalStateException("Flutter engine detached")))
        configureCallback = null
        permissionCallback?.invoke(Result.failure(IllegalStateException("Flutter engine detached")))
        permissionCallback = null
        activity = null
        events.detach()
        releaseNativeSdkIfIdle()
    }

    private fun trackingListener(): Asleep.AsleepTrackingListener =
        object : Asleep.AsleepTrackingListener {
            private var failedTerminally = false

            override fun onStart(sessionId: String) {
                emit("onTrackingCreated", mapOf("sessionId" to sessionId))
            }

            override fun onPerform(sequence: Int) {
                emit("onTrackingUploaded", mapOf("sequence" to sequence))
            }

            override fun onFinish(sessionId: String?) {
                if (failedTerminally) {
                    if (loggingEnabled) {
                        emit(
                            "onDebugLog",
                            mapOf("message" to "Tracking close suppressed after terminal failure"),
                        )
                    }
                    return
                }
                emit("onTrackingClosed", mapOf("sessionId" to (sessionId ?: "")))
            }

            override fun onFail(errorCode: Int, detail: String) {
                failedTerminally = errorCode in TERMINAL_TRACKING_ERROR_CODES
                val code =
                    if (errorCode == 23499) "UPLOAD_TRACKING_TERMINATED" else "TRACKING_FAILED"
                emit("onTrackingFailed", errorPayload(errorCode, detail, code))
            }
        }

    private fun hasRequiredPermissions(): Boolean =
        isPermissionGranted(Manifest.permission.RECORD_AUDIO) &&
            (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                    isPermissionGranted(Manifest.permission.FOREGROUND_SERVICE_MICROPHONE)
            )

    private fun permissionsToRequest(): List<String> =
        buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

    private fun isPermissionGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun finishConfigure(result: Result<Unit>) {
        configureCallback?.invoke(result)
        configureCallback = null
        configureInFlight = false
        releaseNativeSdkIfIdle()
    }

    private fun configureAfterSetup(message: SetupMessage) {
        try {
            Asleep.initAsleepConfig(
                context = context,
                apiKey = message.apiKey,
                userId = null,
                baseUrl = message.baseUrl,
                callbackUrl = message.callbackUrl,
                service = message.service ?: "SleepTracking",
                asleepConfigListener = object : Asleep.AsleepConfigListener {
                    override fun onSuccess(userId: String?, asleepConfig: AsleepConfig?) {
                        if (asleepConfig == null) {
                            val error = IllegalStateException("Native AsleepConfig is null after setup")
                            emit(
                                "onSetupDidFail",
                                mapOf(
                                    "code" to "CONFIG_ERROR",
                                    "message" to error.message,
                                ),
                            )
                            finishSetup(Result.failure(error))
                            return
                        }
                        this@AndroidAsleepHostApi.asleepConfig = asleepConfig
                        reports = Asleep.createReports(asleepConfig)
                        if (userId != null) {
                            emit("onUserJoined", mapOf("userId" to userId))
                        }
                        emit("onSetupDidComplete")
                        finishSetup(Result.success(Unit))
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        val payload = errorPayload(errorCode, detail, "INIT_CONFIG_FAILED")
                        emit("onUserJoinFailed", payload)
                        emit("onSetupDidFail", payload)
                        finishSetup(Result.failure(NativeSdkException(errorCode, detail)))
                    }
                },
            )
        } catch (error: Throwable) {
            emit(
                "onSetupDidFail",
                mapOf(
                    "code" to "INIT_CONFIG_FAILED",
                    "message" to (error.message ?: "Configuration after setup failed"),
                ),
            )
            finishSetup(Result.failure(error))
        }
    }

    private fun finishSetup(result: Result<Unit>) {
        setupCallback?.invoke(result)
        setupCallback = null
        setupInFlight = false
        releaseNativeSdkIfIdle()
    }

    private fun <T> claimNativeSdk(callback: (Result<T>) -> Unit): Boolean {
        if (NativeSdkOwnerRegistry.claim(this)) return true
        callback(
            Result.failure(
                IllegalStateException(
                    "The Asleep native SDK is already owned by another Flutter engine",
                ),
            ),
        )
        return false
    }

    private fun <T> requireNativeSdkOwner(callback: (Result<T>) -> Unit): Boolean {
        if (NativeSdkOwnerRegistry.isOwner(this)) return true
        callback(
            Result.failure(
                IllegalStateException(
                    "This Flutter engine does not own the Asleep native SDK; initialize it first",
                ),
            ),
        )
        return false
    }

    private fun releaseNativeSdkIfIdle() {
        if (detached && !setupInFlight && !configureInFlight) {
            NativeSdkOwnerRegistry.release(this)
        }
    }

    private fun emit(type: String, payload: Map<String, Any?> = emptyMap()) {
        events.emit(type, gson.toJson(payload))
    }

    private fun emitJson(type: String, payloadJson: String) {
        events.emit(type, payloadJson)
    }

    private fun errorPayload(errorCode: Int, detail: String, code: String): Map<String, Any?> =
        mapOf(
            "code" to code,
            "message" to detail,
            "error" to detail,
            "sdkCode" to errorCode,
            "platformDetails" to mapOf("platform" to "android"),
        )

    private fun <T> requireReports(callback: (Result<T>) -> Unit): Reports? {
        val current = reports
        if (current == null) {
            callback(Result.failure(IllegalStateException("Reports are not initialized")))
        }
        return current
    }
}

private class NativeSdkException(
    val sdkCode: Int,
    detail: String,
) : RuntimeException(detail)
