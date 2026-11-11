package com.bexxcord.app

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Context
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.provider.Settings
import android.view.Display
import android.view.WindowManager

enum class VideoCodecKind(val mimeType: String, val mediaStoreTag: String) {
    H264(MediaFormat.MIMETYPE_VIDEO_AVC, "h264"),
    H265(MediaFormat.MIMETYPE_VIDEO_HEVC, "h265");

    companion object {
        fun fromTag(tag: String): VideoCodecKind? = entries.firstOrNull { it.mediaStoreTag == tag }
    }
}

enum class AudioSourceKind(val mediaStoreTag: String) {
    SYSTEM_PLAYBACK("sys"),
    MICROPHONE("mic"),
    NONE("mute")
}

data class RecordingConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val videoBitrateBps: Long,
    val audioBitrateBps: Long,
    val codec: VideoCodecKind,
    val micEnabled: Boolean,
    val systemAudioEnabled: Boolean
)

data class ConfigValidationError(val code: String, val message: String)

data class RecorderCapabilities(
    val apiLevel: Int,
    val mediaProjectionSupported: Boolean,
    val displayWidth: Int,
    val displayHeight: Int,
    val displayRefreshRate: Int,
    val h264Encoder: String?,
    val h265Encoder: String?,
    val maxVideoBitrateBps: Long,
    val systemPlaybackSupported: Boolean,
    val systemPlaybackUnavailableReason: String?,
    val microphoneSupported: Boolean,
    val overlayPermissionGranted: Boolean,
    val notificationPermissionGranted: Boolean,
    val thermalStatusSupported: Boolean,
    val thermalHeadroomSupported: Boolean,
    val freeStorageBytes: Long,
    val pipeline: String
) {
    fun toContractMap(): Map<String, Any?> = mapOf(
        "apiLevel" to apiLevel,
        "mediaProjectionSupported" to mediaProjectionSupported,
        "displayWidth" to displayWidth,
        "displayHeight" to displayHeight,
        "displayRefreshRate" to displayRefreshRate,
        "h264Encoder" to h264Encoder,
        "h265Encoder" to h265Encoder,
        "maxVideoBitrateBps" to maxVideoBitrateBps,
        "systemPlaybackSupported" to systemPlaybackSupported,
        "systemPlaybackUnavailableReason" to systemPlaybackUnavailableReason,
        "microphoneSupported" to microphoneSupported,
        "overlayPermissionGranted" to overlayPermissionGranted,
        "notificationPermissionGranted" to notificationPermissionGranted,
        "thermalStatusSupported" to thermalStatusSupported,
        "thermalHeadroomSupported" to thermalHeadroomSupported,
        "freeStorageBytes" to freeStorageBytes,
        "pipeline" to pipeline
    )

    fun encoderNameFor(codec: VideoCodecKind): String? = when (codec) {
        VideoCodecKind.H264 -> h264Encoder
        VideoCodecKind.H265 -> h265Encoder
    }
}

object CapabilityProbe {

    @SuppressLint("WrongConstant")
    fun probe(context: Context): RecorderCapabilities {
        val display = resolveDisplay(context)
        val point = android.graphics.Point()
        display?.getRealSize(point)
        val apiLevel = Build.VERSION.SDK_INT
        val systemPlaybackSupported = apiLevel >= Build.VERSION_CODES.Q
        val h264Encoder = findHardwareEncoder(MediaFormat.MIMETYPE_VIDEO_AVC)
        val h265Encoder = findHardwareEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC)
        val maxBitrate = findMaxBitrate(MediaFormat.MIMETYPE_VIDEO_AVC)
        val thermalHeadroomSupported = apiLevel >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val freeStorageBytes = measureFreeStorage(context)
        return RecorderCapabilities(
            apiLevel = apiLevel,
            mediaProjectionSupported = apiLevel >= Build.VERSION_CODES.Q,
            displayWidth = point.x,
            displayHeight = point.y,
            displayRefreshRate = display?.refreshRate?.toInt() ?: 60,
            h264Encoder = h264Encoder,
            h265Encoder = h265Encoder,
            maxVideoBitrateBps = maxBitrate,
            systemPlaybackSupported = systemPlaybackSupported,
            systemPlaybackUnavailableReason = if (systemPlaybackSupported) {
                null
            } else {
                "playback_capture_requires_api_29"
            },
            microphoneSupported = context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_MICROPHONE),
            overlayPermissionGranted = Settings.canDrawOverlays(context),
            notificationPermissionGranted = notificationManager.areNotificationsEnabled(),
            thermalStatusSupported = apiLevel >= Build.VERSION_CODES.Q,
            thermalHeadroomSupported = thermalHeadroomSupported,
            freeStorageBytes = freeStorageBytes,
            pipeline = "MediaCodec+MediaMuxer"
        )
    }

    fun validate(config: RecordingConfig, capabilities: RecorderCapabilities): ConfigValidationError? {
        val encoderName = capabilities.encoderNameFor(config.codec) ?: return ConfigValidationError(
            "CONFIG_CODEC_MISSING",
            "no encoder available for ${config.codec.mimeType} on this device"
        )
        if (config.width <= 0 || config.height <= 0) return ConfigValidationError(
            "CONFIG_RESOLUTION_INVALID",
            "resolution must be positive"
        )
        if (config.width % 2 != 0 || config.height % 2 != 0) return ConfigValidationError(
            "CONFIG_RESOLUTION_UNALIGNED",
            "encoder requires even width and height"
        )
        if (capabilities.displayWidth > 0 && (config.width > capabilities.displayWidth || config.height > capabilities.displayHeight)) {
            return ConfigValidationError(
                "CONFIG_RESOLUTION_EXCEEDS_DISPLAY",
                "requested ${config.width}x${config.height} exceeds display ${capabilities.displayWidth}x${capabilities.displayHeight}"
            )
        }
        if (!supportsSizeAndRate(encoderName, config.codec.mimeType, config.width, config.height, config.fps)) {
            return ConfigValidationError(
                "CONFIG_FPS_UNSUPPORTED",
                "encoder cannot sustain ${config.width}x${config.height} at ${config.fps}fps"
            )
        }
        val minBitrate = 1_000_000L
        val codecMaxBitrate = findMaxBitrate(config.codec.mimeType)
        if (config.videoBitrateBps < minBitrate || (codecMaxBitrate in 1 until config.videoBitrateBps)) {
            return ConfigValidationError(
                "CONFIG_BITRATE_OUT_OF_RANGE",
                "video bitrate ${config.videoBitrateBps} outside ${config.codec.mediaStoreTag} supported range"
            )
        }
        if (config.audioBitrateBps !in 32_000L..320_000L) return ConfigValidationError(
            "CONFIG_AUDIO_BITRATE_OUT_OF_RANGE",
            "audio bitrate ${config.audioBitrateBps} outside supported range"
        )
        if (config.systemAudioEnabled && !capabilities.systemPlaybackSupported) return ConfigValidationError(
            "CONFIG_AUDIO_UNAVAILABLE",
            capabilities.systemPlaybackUnavailableReason ?: "system playback capture unsupported"
        )
        val estimatedReserveBytes = estimateSessionBytes(config)
        if (capabilities.freeStorageBytes in 1..estimatedReserveBytes) {
            return ConfigValidationError(
                "STORAGE_LOW",
                "free storage ${capabilities.freeStorageBytes / (1024L * 1024L)}MB below five minute reserve ${estimatedReserveBytes / (1024L * 1024L)}MB"
            )
        }
        return null
    }

    fun estimateSessionBytes(config: RecordingConfig): Long {
        val combinedBitrate = config.videoBitrateBps + config.audioBitrateBps
        return combinedBitrate * 60L * 5L * 11L / 10L
    }

    fun measureFreeStorage(context: Context): Long {
        val dir = context.getExternalFilesDir(null) ?: return 0L
        return runCatching { android.os.StatFs(dir.absolutePath).availableBytes }.getOrDefault(0L)
    }

    @Suppress("DEPRECATION")
    private fun resolveDisplay(context: Context): Display? {
        val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return null
        return windowManager.defaultDisplay
    }

    private fun findHardwareEncoder(mimeType: String): String? {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val encoders = codecList.codecInfos.filter {
            it.isEncoder && it.supportedTypes.any { type -> type.equals(mimeType, ignoreCase = true) }
        }
        return encoders.firstOrNull { it.isHardwareAccelerated }?.name ?: encoders.firstOrNull()?.name
    }

    private fun findMaxBitrate(mimeType: String): Long {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val encoder = codecList.codecInfos.firstOrNull {
            it.isEncoder && it.supportedTypes.any { type -> type.equals(mimeType, ignoreCase = true) }
        } ?: return 0L
        val caps = encoder.getCapabilitiesForType(mimeType) ?: return 0L
        return caps.videoCapabilities?.bitrateRange?.upper ?: 0L
    }

    private fun supportsSizeAndRate(encoderName: String, mimeType: String, width: Int, height: Int, fps: Int): Boolean {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val encoder = codecList.codecInfos.firstOrNull { it.name == encoderName } ?: return false
        val caps = encoder.getCapabilitiesForType(mimeType) ?: return false
        val videoCaps = caps.videoCapabilities ?: return false
        return videoCaps.isSizeAndRateSupported(width, height, fps.toDouble())
    }
}
