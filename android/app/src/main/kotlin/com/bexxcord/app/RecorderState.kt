package com.bexxcord.app

sealed class RecorderState {
    abstract val kind: String

    data object Idle : RecorderState() {
        override val kind: String = "idle"
    }

    data class Preparing(val profileLabel: String) : RecorderState() {
        override val kind: String = "preparing"
    }

    data class RequestingPermission(val permission: String) : RecorderState() {
        override val kind: String = "requestingPermission"
    }

    data class Starting(val profileLabel: String) : RecorderState() {
        override val kind: String = "starting"
    }

    data class Recording(
        val startedAtEpochMs: Long,
        val elapsedMs: Long,
        val fps: Double,
        val droppedFrames: Int,
        val segmentCount: Int,
        val audioSource: String
    ) : RecorderState() {
        override val kind: String = "recording"
    }

    data class Paused(
        val startedAtEpochMs: Long,
        val elapsedMs: Long,
        val droppedFrames: Int,
        val segmentCount: Int,
        val audioSource: String
    ) : RecorderState() {
        override val kind: String = "paused"
    }

    data class Stopping(val elapsedMs: Long) : RecorderState() {
        override val kind: String = "stopping"
    }

    data class Finalizing(val segmentCount: Int) : RecorderState() {
        override val kind: String = "finalizing"
    }

    data class Saved(
        val uri: String,
        val durationMs: Long,
        val sizeBytes: Long,
        val width: Int,
        val height: Int,
        val fps: Int,
        val codecTag: String,
        val audioTag: String,
        val segmentCount: Int
    ) : RecorderState() {
        override val kind: String = "saved"
    }

    data class Error(val code: String, val message: String, val recoverable: Boolean) : RecorderState() {
        override val kind: String = "error"
    }

    data class Interrupted(val reason: String) : RecorderState() {
        override val kind: String = "interrupted"
    }

    fun toContractMap(): Map<String, Any?> = when (this) {
        is Idle -> mapOf("state" to kind)
        is Preparing -> mapOf("state" to kind, "profileLabel" to profileLabel)
        is RequestingPermission -> mapOf("state" to kind, "permission" to permission)
        is Starting -> mapOf("state" to kind, "profileLabel" to profileLabel)
        is Recording -> mapOf(
            "state" to kind,
            "startedAtEpochMs" to startedAtEpochMs,
            "elapsedMs" to elapsedMs,
            "fps" to fps,
            "droppedFrames" to droppedFrames,
            "segmentCount" to segmentCount,
            "audioSource" to audioSource
        )
        is Paused -> mapOf(
            "state" to kind,
            "startedAtEpochMs" to startedAtEpochMs,
            "elapsedMs" to elapsedMs,
            "droppedFrames" to droppedFrames,
            "segmentCount" to segmentCount,
            "audioSource" to audioSource
        )
        is Stopping -> mapOf("state" to kind, "elapsedMs" to elapsedMs)
        is Finalizing -> mapOf("state" to kind, "segmentCount" to segmentCount)
        is Saved -> mapOf(
            "state" to kind,
            "uri" to uri,
            "durationMs" to durationMs,
            "sizeBytes" to sizeBytes,
            "width" to width,
            "height" to height,
            "fps" to fps,
            "codecTag" to codecTag,
            "audioTag" to audioTag,
            "segmentCount" to segmentCount
        )
        is Error -> mapOf("state" to kind, "code" to code, "message" to message, "recoverable" to recoverable)
        is Interrupted -> mapOf("state" to kind, "reason" to reason)
    }
}

data class RecorderTelemetry(
    val fps: Double,
    val droppedFrames: Int,
    val thermalStatus: Int,
    val thermalHeadroom: Double?,
    val elapsedMs: Long,
    val segmentCount: Int,
    val activePipeline: String,
    val audioSource: String
) {
    fun toContractMap(): Map<String, Any?> = mapOf(
        "fps" to fps,
        "droppedFrames" to droppedFrames,
        "thermalStatus" to thermalStatus,
        "thermalHeadroom" to thermalHeadroom,
        "elapsedMs" to elapsedMs,
        "segmentCount" to segmentCount,
        "activePipeline" to activePipeline,
        "audioSource" to audioSource
    )
}

data class RecorderErrorEvent(
    val code: String,
    val message: String,
    val recoverable: Boolean,
    val atEpochMs: Long
) {
    fun toContractMap(): Map<String, Any?> = mapOf(
        "code" to code,
        "message" to message,
        "recoverable" to recoverable,
        "atEpochMs" to atEpochMs
    )
}
