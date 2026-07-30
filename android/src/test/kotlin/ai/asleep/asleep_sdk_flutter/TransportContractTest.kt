package ai.asleep.asleep_sdk_flutter

import android.Manifest
import android.provider.Settings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class TransportContractTest {
    @Test
    fun nativeEventMessageRoundTripsThroughPigeonList() {
        val event =
            NativeEventMessage(
                type = "onTrackingFailed",
                payloadJson = """{"code":"TRACKING_FAILED","sdkCode":11003}""",
            )

        assertEquals(event, NativeEventMessage.fromList(event.toList()))
    }

    @Test
    fun terminalTrackingFailureRemainsStickyAcrossLaterCallbacks() {
        val failedTerminally =
            hasTerminalTrackingFailure(
                alreadyFailedTerminally = false,
                errorCode = 11003,
            )

        assertTrue(failedTerminally)
        assertTrue(
            hasTerminalTrackingFailure(
                alreadyFailedTerminally = failedTerminally,
                errorCode = 21002,
            ),
        )
    }

    @Test
    fun analysisMessagePreservesImmediateResultContract() {
        val message =
            AnalysisRequestMessage(
                status = "completed",
                timestampMilliseconds = 1234,
                resultJson = """{"id":"session"}""",
            )

        assertEquals(message, AnalysisRequestMessage.fromList(message.toList()))
    }

    @Test
    fun nativeSdkOwnershipRejectsASecondEngineDeterministically() {
        val firstEngine = Any()
        val secondEngine = Any()

        try {
            assertTrue(NativeSdkOwnerRegistry.claim(firstEngine))
            assertTrue(NativeSdkOwnerRegistry.claim(firstEngine))
            assertFalse(NativeSdkOwnerRegistry.claim(secondEngine))
        } finally {
            NativeSdkOwnerRegistry.release(firstEngine)
        }

        assertTrue(NativeSdkOwnerRegistry.claim(secondEngine))
        NativeSdkOwnerRegistry.release(secondEngine)
    }

    @Test
    fun requiredPermissionsDoNotTreatNotificationVisibilityAsTrackingPrerequisite() {
        assertEquals(listOf(Manifest.permission.RECORD_AUDIO), requiredRuntimePermissions())
        assertFalse(requiredRuntimePermissions().contains(Manifest.permission.POST_NOTIFICATIONS))
    }

    @Test
    fun batteryOptimizationDirectRequestRequiresConsumerManifestOptIn() {
        assertEquals(
            Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
            batteryOptimizationSettingsAction(canRequestDirectExemption = false),
        )
        assertEquals(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            batteryOptimizationSettingsAction(canRequestDirectExemption = true),
        )
    }

    @Test
    fun nativeSdkErrorPreservesNumericCodeInPigeonDetails() {
        val error = nativeSdkError(23499, "Upload terminated")

        assertEquals("NATIVE_SDK_ERROR", error.code)
        assertEquals("Upload terminated", error.message)
        val details = error.details as Map<*, *>
        assertEquals(23499, details["sdkCode"])
        assertEquals("android", details["platform"])
    }

    @Test
    fun trackingStartCompletesOnlyAfterNativeStartAcknowledgement() {
        val scheduled = mutableListOf<Runnable>()
        val cancelled = mutableListOf<Runnable>()
        var result: Result<Unit>? = null
        val coordinator =
            TrackingStartCoordinator(
                schedule = { runnable, _ -> scheduled += runnable },
                cancel = { cancelled += it },
            )

        val attempt = assertNotNull(coordinator.begin { result = it })
        assertTrue(coordinator.isInFlight)
        assertNull(result)
        assertTrue(coordinator.succeed(attempt))

        assertTrue(assertNotNull(result).isSuccess)
        assertFalse(coordinator.isInFlight)
        assertEquals(scheduled, cancelled)
    }

    @Test
    fun trackingStartFailsFromNativeCallbackAndRejectsDuplicateAttempt() {
        var firstResult: Result<Unit>? = null
        var secondCalled = false
        val coordinator =
            TrackingStartCoordinator(
                schedule = { _, _ -> },
                cancel = {},
            )

        val attempt = assertNotNull(coordinator.begin { firstResult = it })
        assertNull(coordinator.begin { secondCalled = true })
        assertFalse(secondCalled)

        val failure = nativeSdkError(11003, "No mic")
        assertTrue(coordinator.fail(attempt, failure))
        assertEquals(failure, assertNotNull(firstResult).exceptionOrNull())
        assertFalse(coordinator.fail(attempt, IllegalStateException("late failure")))
    }

    @Test
    fun trackingStartTimesOutWhenNativeSdkNeverAcknowledges() {
        var timeout: Runnable? = null
        var result: Result<Unit>? = null
        var timeoutRecoveryCount = 0
        val coordinator =
            TrackingStartCoordinator(
                schedule = { runnable, delay ->
                    assertEquals(TRACKING_START_TIMEOUT_MILLIS, delay)
                    timeout = runnable
                },
                cancel = {},
                onTimeout = { timeoutRecoveryCount += 1 },
            )

        val attempt = assertNotNull(coordinator.begin { result = it })
        assertNull(result)
        assertNotNull(timeout).run()

        val error = assertNotNull(result).exceptionOrNull() as FlutterError
        assertEquals("TRACKING_START_TIMEOUT", error.code)
        assertEquals(1, timeoutRecoveryCount)
        assertFalse(coordinator.isInFlight)
        assertFalse(coordinator.isLatest(attempt))
        assertFalse(coordinator.succeed(attempt))
    }

    @Test
    fun trackingStartIgnoresCallbacksFromAnOlderAttempt() {
        val scheduled = mutableListOf<Runnable>()
        var firstResult: Result<Unit>? = null
        var secondResult: Result<Unit>? = null
        val coordinator =
            TrackingStartCoordinator(
                schedule = { runnable, _ -> scheduled += runnable },
                cancel = {},
            )

        val firstAttempt = assertNotNull(coordinator.begin { firstResult = it })
        scheduled.single().run()
        assertNotNull(firstResult).exceptionOrNull()

        val secondAttempt = assertNotNull(coordinator.begin { secondResult = it })
        assertFalse(coordinator.isLatest(firstAttempt))
        assertTrue(coordinator.isLatest(secondAttempt))
        assertFalse(coordinator.succeed(firstAttempt))
        assertNull(secondResult)

        assertTrue(coordinator.succeed(secondAttempt))
        assertTrue(assertNotNull(secondResult).isSuccess)
    }

    @Test
    fun trackingRestorerProbesBeforeSetupAndRechecksBeforeConnecting() {
        val aliveResults = ArrayDeque(listOf(true, true))
        var connectCount = 0
        val restorer =
            TrackingRestorer(
                isTrackingAlive = { aliveResults.removeFirst() },
                connectTracking = { connectCount += 1 },
            )

        assertTrue(restorer.wasAliveAtAttachment)
        assertTrue(restorer.restore())
        assertEquals(1, connectCount)
    }

    @Test
    fun trackingRestorerNeverConnectsOrReportsActiveFromStaleAttachmentProbe() {
        val aliveResults = ArrayDeque(listOf(true, false))
        var connected = false
        val restorer =
            TrackingRestorer(
                isTrackingAlive = { aliveResults.removeFirst() },
                connectTracking = { connected = true },
            )

        assertTrue(restorer.wasAliveAtAttachment)
        assertFalse(restorer.restore())
        assertFalse(connected)
    }

    @Test
    fun nativeLoggerForwardsOnlyWhileEnabled() {
        var enabled = false
        val entries = mutableListOf<List<Any?>>()
        val logger =
            DynamicAsleepLogger(
                isEnabled = { enabled },
                emit = { level, tag, message, throwable ->
                    entries += listOf(level, tag, message, throwable)
                },
            )

        logger.d("sdk", "hidden", null)
        assertTrue(entries.isEmpty())

        enabled = true
        logger.w("sdk", "visible", null)
        assertEquals(
            listOf<List<Any?>>(listOf("warn", "sdk", "visible", null)),
            entries,
        )
    }

    @Test
    fun reportPagerLoadsEveryPageUntilTheFirstPartialPage() {
        val offsets = mutableListOf<Int>()
        val firstPage = (0 until 100).toList()
        val secondPage = listOf(100, 101)
        var result: Result<List<Int>>? = null
        val pager =
            ReportPager<Int>(
                pageSize = 100,
                loadPage = { offset, limit, callback ->
                    assertEquals(100, limit)
                    offsets += offset
                    callback(
                        Result.success(
                            when (offset) {
                                0 -> firstPage
                                100 -> secondPage
                                else -> error("Unexpected offset $offset")
                            },
                        ),
                    )
                },
            )

        pager.loadAll { result = it }

        assertEquals(listOf(0, 100), offsets)
        assertEquals(firstPage + secondPage, assertNotNull(result).getOrThrow())
    }

    @Test
    fun reportPagerStopsImmediatelyOnNativeFailure() {
        val failure = nativeSdkError(24000, "Report failed")
        var result: Result<List<Int>>? = null
        val pager =
            ReportPager<Int>(
                pageSize = 100,
                loadPage = { _, _, callback -> callback(Result.failure(failure)) },
            )

        pager.loadAll { result = it }

        assertEquals(failure, assertNotNull(result).exceptionOrNull())
    }
}
