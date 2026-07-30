package ai.asleep.asleep_sdk_flutter

import ai.asleep.asleepsdk.Asleep
import ai.asleep.asleepsdk.data.AsleepConfig
import ai.asleep.asleepsdk.data.AverageReport
import ai.asleep.asleepsdk.data.Report
import ai.asleep.asleepsdk.data.Session
import ai.asleep.asleepsdk.data.SleepSession
import ai.asleep.asleepsdk.tracking.Reports
import android.Manifest
import android.annotation.SuppressLint
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

internal const val TRACKING_START_TIMEOUT_MILLIS = 30_000L
internal const val INITIALIZATION_TIMEOUT_MILLIS = 30_000L

internal val TERMINAL_TRACKING_ERROR_CODES =
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

internal fun hasTerminalTrackingFailure(alreadyFailedTerminally: Boolean, errorCode: Int): Boolean =
    alreadyFailedTerminally || errorCode in TERMINAL_TRACKING_ERROR_CODES

internal fun requiredRuntimePermissions(): List<String> =
    listOf(Manifest.permission.RECORD_AUDIO)

@SuppressLint("BatteryLife")
internal fun batteryOptimizationSettingsAction(
    canRequestDirectExemption: Boolean,
): String =
    if (canRequestDirectExemption) {
        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
    } else {
        Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
    }

internal fun nativeSdkError(errorCode: Int, detail: String): FlutterError =
    FlutterError(
        code = "NATIVE_SDK_ERROR",
        message = detail,
        details =
            mapOf(
                "sdkCode" to errorCode,
                "platform" to "android",
            ),
    )

internal class TrackingStartCoordinator(
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val onTimeout: () -> Unit = {},
) {
    private var callback: ((Result<Unit>) -> Unit)? = null
    private var timeout: Runnable? = null
    private var nextAttempt = 0L
    private var activeAttempt: Long? = null
    private var latestAttempt: Long? = null

    fun begin(callback: (Result<Unit>) -> Unit): Long? {
        if (this.callback != null) return null
        val attempt = ++nextAttempt
        this.callback = callback
        activeAttempt = attempt
        latestAttempt = attempt
        val timeout =
            Runnable {
                if (activeAttempt == attempt) {
                    onTimeout()
                    finish(
                        attempt,
                        Result.failure(
                            FlutterError(
                                code = "TRACKING_START_TIMEOUT",
                                message = "The native Asleep SDK did not acknowledge tracking start",
                            ),
                        ),
                        keepLatest = false,
                    )
                }
            }
        this.timeout = timeout
        schedule(timeout, TRACKING_START_TIMEOUT_MILLIS)
        return attempt
    }

    fun succeed(attempt: Long): Boolean =
        finish(attempt, Result.success(Unit), keepLatest = true)

    fun fail(attempt: Long, error: Throwable): Boolean =
        finish(attempt, Result.failure(error), keepLatest = false)

    fun failCurrent(error: Throwable): Boolean {
        val attempt = activeAttempt ?: return false
        return fail(attempt, error)
    }

    fun isLatest(attempt: Long): Boolean = latestAttempt == attempt

    val isInFlight: Boolean
        get() = callback != null

    private fun finish(
        attempt: Long,
        result: Result<Unit>,
        keepLatest: Boolean,
    ): Boolean {
        if (activeAttempt != attempt) return false
        val currentCallback = callback ?: return false
        callback = null
        activeAttempt = null
        if (!keepLatest && latestAttempt == attempt) {
            latestAttempt = null
        }
        timeout?.let(cancel)
        timeout = null
        currentCallback(result)
        return true
    }
}

internal class InitializationCoordinator(
    private val operation: String,
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val onTimeout: () -> Unit = {},
) {
    private var callback: ((Result<Unit>) -> Unit)? = null
    private var timeout: Runnable? = null
    private var nextAttempt = 0L
    private var activeAttempt: Long? = null

    fun begin(callback: (Result<Unit>) -> Unit): Long? {
        if (activeAttempt != null) return null
        val attempt = ++nextAttempt
        activeAttempt = attempt
        this.callback = callback
        scheduleTimeout(attempt)
        return attempt
    }

    fun refreshTimeout(attempt: Long): Boolean {
        if (!isAwaiting(attempt)) return false
        timeout?.let(cancel)
        scheduleTimeout(attempt)
        return true
    }

    fun isAwaiting(attempt: Long): Boolean =
        activeAttempt == attempt && callback != null

    fun finish(attempt: Long, result: Result<Unit>): Boolean {
        if (activeAttempt != attempt) return false
        val currentCallback = callback
        clear()
        currentCallback?.invoke(result)
        return currentCallback != null
    }

    fun failWaiter(error: Throwable) {
        val currentCallback = callback
        timeout?.let(cancel)
        timeout = null
        callback = null
        // Keep activeAttempt quarantined until its native listener terminates.
        currentCallback?.invoke(Result.failure(error))
    }

    val isBusy: Boolean
        get() = activeAttempt != null

    private fun scheduleTimeout(attempt: Long) {
        val timeout =
            Runnable {
                if (!isAwaiting(attempt)) return@Runnable
                val currentCallback = callback
                // The native SDK has one process-global listener and no cancellation API.
                // Fail the Dart waiter, but keep this attempt active to prevent overlap.
                callback = null
                this.timeout = null
                onTimeout()
                currentCallback?.invoke(
                    Result.failure(
                        FlutterError(
                            code = "INITIALIZATION_TIMEOUT",
                            message = "The native Asleep SDK did not complete $operation",
                        ),
                    ),
                )
            }
        this.timeout = timeout
        schedule(timeout, INITIALIZATION_TIMEOUT_MILLIS)
    }

    private fun clear() {
        timeout?.let(cancel)
        timeout = null
        callback = null
        activeAttempt = null
    }
}

internal class TrackingRestorer(
    private val isTrackingAlive: () -> Boolean,
    private val connectTracking: () -> Unit,
) {
    val wasAliveAtAttachment: Boolean = runCatching(isTrackingAlive).getOrDefault(false)

    fun restore(): Boolean {
        if (!isTrackingAlive()) return false
        connectTracking()
        return true
    }
}

internal class ReportPager<T>(
    private val pageSize: Int,
    private val loadPage: (offset: Int, limit: Int, callback: (Result<List<T>>) -> Unit) -> Unit,
) {
    fun loadAll(callback: (Result<List<T>>) -> Unit) {
        loadNext(offset = 0, accumulated = emptyList(), callback = callback)
    }

    private fun loadNext(
        offset: Int,
        accumulated: List<T>,
        callback: (Result<List<T>>) -> Unit,
    ) {
        loadPage(offset, pageSize) { result ->
            result.fold(
                onSuccess = { page ->
                    val combined = accumulated + page
                    if (page.size < pageSize) {
                        callback(Result.success(combined))
                    } else {
                        loadNext(
                            offset = offset + page.size,
                            accumulated = combined,
                            callback = callback,
                        )
                    }
                },
                onFailure = { callback(Result.failure(it)) },
            )
        }
    }
}

internal class DynamicAsleepLogger(
    private val isEnabled: () -> Boolean,
    private val emit: (level: String, tag: String, message: String, throwable: Throwable?) -> Unit,
) : Asleep.AsleepLogger {
    override fun d(tag: String, msg: String, throwable: Throwable?) =
        forward("debug", tag, msg, throwable)

    override fun e(tag: String, msg: String, throwable: Throwable?) =
        forward("error", tag, msg, throwable)

    override fun i(tag: String, msg: String, throwable: Throwable?) =
        forward("info", tag, msg, throwable)

    override fun w(tag: String, msg: String, throwable: Throwable?) =
        forward("warn", tag, msg, throwable)

    private fun forward(level: String, tag: String, message: String, throwable: Throwable?) {
        if (isEnabled()) {
            emit(level, tag, message, throwable)
        }
    }
}

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

    fun emit(
        type: String,
        payloadJson: String,
        shouldDeliver: () -> Boolean = { true },
        completion: (() -> Unit)? = null,
    ) {
        val deliver =
            Runnable {
                if (!shouldDeliver()) return@Runnable
                sink?.success(NativeEventMessage(type = type, payloadJson = payloadJson))
                completion?.invoke()
            }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver.run()
        } else {
            mainHandler.post(deliver)
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
    }

    private val gson = Gson()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var asleepConfig: AsleepConfig? = null
    private var reports: Reports? = null
    @Volatile
    private var loggingEnabled = false
    private var permissionCallback: ((Result<Boolean>) -> Unit)? = null
    private var detached = false
    private var startRecoveryRequired = false
    private val setupCoordinator =
        InitializationCoordinator(
            operation = "setup",
            schedule = mainHandler::postDelayed,
            cancel = mainHandler::removeCallbacks,
            onTimeout = {
                emit(
                    "onSetupDidFail",
                    mapOf(
                        "code" to "INITIALIZATION_TIMEOUT",
                        "message" to "The native Asleep SDK did not complete setup",
                    ),
                )
            },
        )
    private val configureCoordinator =
        InitializationCoordinator(
            operation = "configuration",
            schedule = mainHandler::postDelayed,
            cancel = mainHandler::removeCallbacks,
        )
    private val trackingStartCoordinator =
        TrackingStartCoordinator(
            schedule = mainHandler::postDelayed,
            cancel = mainHandler::removeCallbacks,
            onTimeout = {
                startRecoveryRequired = true
                runCatching(Asleep::endSleepTracking)
            },
        )
    private val nativeLogger =
        DynamicAsleepLogger(
            isEnabled = { loggingEnabled },
            emit = ::emitNativeLog,
        )
    private val trackingRestorer =
        TrackingRestorer(
            isTrackingAlive = { Asleep.isSleepTrackingAlive(context) },
            connectTracking = { Asleep.connectSleepTracking(trackingListener()) },
        )
    var activity: Activity? = null

    override fun setup(message: SetupMessage, callback: (Result<Unit>) -> Unit) {
        if (!claimNativeSdk(callback)) return
        if (setupCoordinator.isBusy || configureCoordinator.isBusy) {
            callback(Result.failure(IllegalStateException("Setup or configuration is already in progress")))
            return
        }
        val attempt = setupCoordinator.begin(callback) ?: return
        try {
            Asleep.setup(
                context = context,
                apiKey = message.apiKey,
                baseUrl = message.baseUrl,
                callbackUrl = message.callbackUrl,
                service = message.service ?: "SleepTracking",
                enableODA = message.enableOnDeviceAnalysis,
                asleepLogger = nativeLogger,
                asleepSetupListener = object : Asleep.AsleepSetupListener {
                    override fun onComplete() {
                        if (!setupCoordinator.isAwaiting(attempt)) {
                            finishSetup(attempt, Result.success(Unit))
                            return
                        }
                        setupCoordinator.refreshTimeout(attempt)
                        configureAfterSetup(message, attempt)
                    }

                    override fun onProgress(progress: Int) {
                        if (!setupCoordinator.isAwaiting(attempt)) return
                        emit("onSetupInProgress", mapOf("progress" to progress))
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        if (!setupCoordinator.isAwaiting(attempt)) {
                            finishSetup(attempt, Result.failure(nativeSdkError(errorCode, detail)))
                            return
                        }
                        emit("onSetupDidFail", errorPayload(errorCode, detail, "SETUP_FAILED"))
                        finishSetup(attempt, Result.failure(nativeSdkError(errorCode, detail)))
                    }
                },
            )
        } catch (error: Throwable) {
            finishSetup(attempt, Result.failure(error))
        }
    }

    override fun configure(message: ConfigurationMessage, callback: (Result<Unit>) -> Unit) {
        if (!claimNativeSdk(callback)) return
        if (setupCoordinator.isBusy || configureCoordinator.isBusy) {
            callback(Result.failure(IllegalStateException("Configuration is already in progress")))
            return
        }
        val attempt = configureCoordinator.begin(callback) ?: return
        try {
            Asleep.initAsleepConfig(
                context = context,
                apiKey = message.apiKey,
                userId = message.userId,
                baseUrl = message.baseUrl,
                callbackUrl = message.callbackUrl,
                service = "SleepTracking",
                asleepLogger = nativeLogger,
                asleepConfigListener = object : Asleep.AsleepConfigListener {
                    override fun onSuccess(userId: String?, asleepConfig: AsleepConfig?) {
                        if (!configureCoordinator.isAwaiting(attempt)) {
                            finishConfigure(attempt, Result.success(Unit))
                            return
                        }
                        if (asleepConfig == null) {
                            finishConfigure(
                                attempt,
                                Result.failure(IllegalStateException("Native AsleepConfig is null")),
                            )
                            return
                        }
                        this@AndroidAsleepHostApi.asleepConfig = asleepConfig
                        reports = Asleep.createReports(asleepConfig)
                        userId
                            ?.takeIf(String::isNotEmpty)
                            ?.let { emit("onUserJoined", mapOf("userId" to it)) }
                        finishConfigure(attempt, Result.success(Unit))
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        if (!configureCoordinator.isAwaiting(attempt)) {
                            finishConfigure(attempt, Result.failure(nativeSdkError(errorCode, detail)))
                            return
                        }
                        emit(
                            "onUserJoinFailed",
                            errorPayload(errorCode, detail, "INITIALIZATION_FAILED"),
                        )
                        finishConfigure(attempt, Result.failure(nativeSdkError(errorCode, detail)))
                    }
                },
            )
        } catch (error: Throwable) {
            finishConfigure(attempt, Result.failure(error))
        }
    }

    override fun checkAndRestoreTracking(callback: (Result<RestoreMessage>) -> Unit) {
        // Restoration is intentionally the first native SDK operation during
        // initialization so Android 3.2.1 can bind to a surviving service
        // before setup/configure assigns its process-global context.
        if (!claimNativeSdk(callback)) return
        if (setupCoordinator.isBusy || configureCoordinator.isBusy) {
            callback(
                Result.failure(
                    IllegalStateException(
                        "Setup or configuration is still awaiting native completion",
                    ),
                ),
            )
            return
        }
        try {
            val active = trackingRestorer.restore()
            if (!active) {
                startRecoveryRequired = false
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

    @SuppressLint("BatteryLife")
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
            val canRequestDirectExemption =
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                ) == PackageManager.PERMISSION_GRANTED
            val intent =
                Intent(
                    batteryOptimizationSettingsAction(canRequestDirectExemption),
                ).apply {
                    if (canRequestDirectExemption) {
                        data = Uri.parse("package:${context.packageName}")
                    }
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
        if (requiredRuntimePermissions().all(::isPermissionGranted)) {
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
            requiredRuntimePermissions().toTypedArray(),
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
        if (startRecoveryRequired) {
            callback(
                Result.failure(
                    FlutterError(
                        code = "TRACKING_START_RECOVERY_REQUIRED",
                        message = "Call checkAndRestoreTracking before retrying a timed-out or cancelled start",
                    ),
                ),
            )
            return
        }
        try {
            if (Asleep.isSleepTrackingAlive(context)) {
                callback(
                    Result.failure(
                        IllegalStateException(
                            "A native tracking session is already active; call checkAndRestoreTracking",
                        ),
                    ),
                )
                return
            }
            val startAttempt = trackingStartCoordinator.begin(callback)
            if (startAttempt == null) {
                callback(Result.failure(IllegalStateException("Tracking start is already in progress")))
                return
            }
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
                asleepTrackingListener = trackingListener(startAttempt),
            )
        } catch (error: Throwable) {
            trackingStartCoordinator.failCurrent(error)
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
            if (
                trackingStartCoordinator.failCurrent(
                    IllegalStateException("Tracking start was cancelled by stopTracking"),
                )
            ) {
                startRecoveryRequired = true
            }
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
                        callback(Result.failure(nativeSdkError(errorCode, detail)))
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
                    callback(Result.failure(nativeSdkError(errorCode, detail)))
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
        ReportPager<SleepSession>(
            pageSize = 100,
            loadPage = { offset, limit, pageCallback ->
                manager.getReports(
                    fromDate,
                    toDate,
                    "DESC",
                    offset,
                    limit,
                    object : Reports.ReportsListener {
                        override fun onSuccess(reports: List<SleepSession>?) {
                            pageCallback(Result.success(reports.orEmpty()))
                        }

                        override fun onFail(errorCode: Int, detail: String) {
                            pageCallback(Result.failure(nativeSdkError(errorCode, detail)))
                        }
                    },
                )
            },
        ).loadAll { result ->
            callback(result.map { reports -> reports.map(gson::toJson) })
        }
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
                    callback(Result.failure(nativeSdkError(errorCode, detail)))
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
                    callback(Result.failure(nativeSdkError(errorCode, detail)))
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
        val detachError = IllegalStateException("Flutter engine detached")
        setupCoordinator.failWaiter(detachError)
        configureCoordinator.failWaiter(detachError)
        permissionCallback?.invoke(Result.failure(IllegalStateException("Flutter engine detached")))
        permissionCallback = null
        trackingStartCoordinator.failCurrent(IllegalStateException("Flutter engine detached"))
        activity = null
        events.detach()
        releaseNativeSdkIfIdle()
    }

    private fun trackingListener(startAttempt: Long? = null): Asleep.AsleepTrackingListener =
        object : Asleep.AsleepTrackingListener {
            private var failedTerminally = false
            private fun isCurrentAttempt(): Boolean =
                startAttempt == null || trackingStartCoordinator.isLatest(startAttempt)

            override fun onStart(sessionId: String) {
                if (!isCurrentAttempt()) return
                emit(
                    "onTrackingCreated",
                    mapOf("sessionId" to sessionId),
                    shouldDeliver = ::isCurrentAttempt,
                ) {
                    startAttempt?.let {
                        if (trackingStartCoordinator.succeed(it)) {
                            startRecoveryRequired = false
                        }
                    }
                }
            }

            override fun onPerform(sequence: Int) {
                if (!isCurrentAttempt()) return
                emit(
                    "onTrackingUploaded",
                    mapOf("sequence" to sequence),
                    shouldDeliver = ::isCurrentAttempt,
                )
            }

            override fun onFinish(sessionId: String?) {
                if (!isCurrentAttempt()) return
                if (failedTerminally) {
                    if (loggingEnabled) {
                        emit(
                            "onDebugLog",
                            mapOf("message" to "Tracking close suppressed after terminal failure"),
                        )
                    }
                    return
                }
                emit(
                    "onTrackingClosed",
                    sessionId
                        ?.takeIf(String::isNotEmpty)
                        ?.let { mapOf("sessionId" to it) }
                        ?: emptyMap(),
                    shouldDeliver = ::isCurrentAttempt,
                ) {
                    startAttempt?.let {
                        trackingStartCoordinator.fail(
                            it,
                            IllegalStateException(
                                "Tracking closed before the native SDK acknowledged its start",
                            ),
                        )
                    }
                }
            }

            override fun onFail(errorCode: Int, detail: String) {
                if (!isCurrentAttempt()) return
                failedTerminally = hasTerminalTrackingFailure(failedTerminally, errorCode)
                val code =
                    if (errorCode == 23499) "UPLOAD_TRACKING_TERMINATED" else "TRACKING_FAILED"
                val failure = nativeSdkError(errorCode, detail)
                emit(
                    "onTrackingFailed",
                    errorPayload(errorCode, detail, code),
                    shouldDeliver = ::isCurrentAttempt,
                ) {
                    startAttempt?.let { trackingStartCoordinator.fail(it, failure) }
                }
            }
        }

    private fun hasRequiredPermissions(): Boolean =
        isPermissionGranted(Manifest.permission.RECORD_AUDIO) &&
            (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                    isPermissionGranted(Manifest.permission.FOREGROUND_SERVICE_MICROPHONE)
            )

    private fun isPermissionGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun finishConfigure(attempt: Long, result: Result<Unit>) {
        configureCoordinator.finish(attempt, result)
        releaseNativeSdkIfIdle()
    }

    private fun configureAfterSetup(message: SetupMessage, attempt: Long) {
        try {
            Asleep.initAsleepConfig(
                context = context,
                apiKey = message.apiKey,
                userId = null,
                baseUrl = message.baseUrl,
                callbackUrl = message.callbackUrl,
                service = message.service ?: "SleepTracking",
                asleepLogger = nativeLogger,
                asleepConfigListener = object : Asleep.AsleepConfigListener {
                    override fun onSuccess(userId: String?, asleepConfig: AsleepConfig?) {
                        if (!setupCoordinator.isAwaiting(attempt)) {
                            finishSetup(attempt, Result.success(Unit))
                            return
                        }
                        if (asleepConfig == null) {
                            val error = IllegalStateException("Native AsleepConfig is null after setup")
                            emit(
                                "onSetupDidFail",
                                mapOf(
                                    "code" to "CONFIG_ERROR",
                                    "message" to error.message,
                                ),
                            )
                            finishSetup(attempt, Result.failure(error))
                            return
                        }
                        this@AndroidAsleepHostApi.asleepConfig = asleepConfig
                        reports = Asleep.createReports(asleepConfig)
                        if (!userId.isNullOrEmpty()) {
                            emit("onUserJoined", mapOf("userId" to userId))
                        }
                        emit("onSetupDidComplete")
                        finishSetup(attempt, Result.success(Unit))
                    }

                    override fun onFail(errorCode: Int, detail: String) {
                        if (!setupCoordinator.isAwaiting(attempt)) {
                            finishSetup(attempt, Result.failure(nativeSdkError(errorCode, detail)))
                            return
                        }
                        val payload = errorPayload(errorCode, detail, "INIT_CONFIG_FAILED")
                        emit("onUserJoinFailed", payload)
                        emit("onSetupDidFail", payload)
                        finishSetup(attempt, Result.failure(nativeSdkError(errorCode, detail)))
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
            finishSetup(attempt, Result.failure(error))
        }
    }

    private fun finishSetup(attempt: Long, result: Result<Unit>) {
        setupCoordinator.finish(attempt, result)
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
        if (detached && !setupCoordinator.isBusy && !configureCoordinator.isBusy) {
            NativeSdkOwnerRegistry.release(this)
        }
    }

    private fun emit(
        type: String,
        payload: Map<String, Any?> = emptyMap(),
        shouldDeliver: () -> Boolean = { true },
        completion: (() -> Unit)? = null,
    ) {
        events.emit(type, gson.toJson(payload), shouldDeliver, completion)
    }

    private fun emitJson(type: String, payloadJson: String) {
        events.emit(type, payloadJson)
    }

    private fun emitNativeLog(
        level: String,
        tag: String,
        message: String,
        throwable: Throwable?,
    ) {
        emit(
            "onDebugLog",
            mapOf(
                "level" to level,
                "tag" to tag,
                "message" to message,
                "throwable" to throwable?.stackTraceToString(),
            ),
        )
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
