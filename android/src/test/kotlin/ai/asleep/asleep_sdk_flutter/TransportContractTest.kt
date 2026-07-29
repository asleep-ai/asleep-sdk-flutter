package ai.asleep.asleep_sdk_flutter

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
}
