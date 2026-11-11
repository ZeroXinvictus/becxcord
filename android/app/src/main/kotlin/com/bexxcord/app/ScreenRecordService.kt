package com.bexxcord.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaProjection
import android.media.MediaProjectionManager
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import android.view.Surface
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.nio.ByteBuffer
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

class ScreenRecordService : Service() {

    companion object {
        const val ACTION_START = "com.bexxcord.app.action.START"
        const val ACTION_PAUSE = "com.bexxcord.app.action.PAUSE"
        const val ACTION_RESUME = "com.bexxcord.app.action.RESUME"
        const val ACTION_STOP = "com.bexxcord.app.action.STOP"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_PROJECTION_DATA = "projection_data"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_FPS = "fps"
        const val EXTRA_VIDEO_BITRATE = "video_bitrate"
        const val EXTRA_AUDIO_BITRATE = "audio_bitrate"
        const val EXTRA_CODEC = "codec"
        const val EXTRA_AUDIO_SOURCE = "audio_source"
        const val EXTRA_PROFILE_LABEL = "profile_label"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "bexxcord_recording"
        private const val SAMPLE_RATE = 44100
    }

    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val commandGate = Mutex()
    private var engine: RecordingEngine? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var telemetryJob: Job? = null
    private var overlayServiceRunning = false
    @Volatile
    private var storageWarned = false
    @Volatile
    private var storageStopTriggered = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bexxcord:record").also {
            it.acquire(6 * 60 * 60 * 1000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: return START_NOT_STICKY
        scope.launch {
            commandGate.withLock {
                runCatching { handleCommand(action, intent) }
                    .onFailure {
                        RecorderBridge.emitError("ENGINE_FAILURE", it.message ?: "unknown engine failure", true)
                    }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        val activeEngine = engine
        if (activeEngine != null) {
            runCatching { activeEngine.release() }
            engine = null
            RecorderBridge.setState(RecorderState.Interrupted("service_destroyed"))
        }
        wakeLock?.let { if (it.isHeld) it.release() }
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun handleCommand(action: String, intent: Intent) {
        when (action) {
            ACTION_START -> handleStart(intent)
            ACTION_PAUSE -> handlePause()
            ACTION_RESUME -> handleResume()
            ACTION_STOP -> handleStop()
        }
    }

    private suspend fun handleStart(intent: Intent) {
        val current = RecorderBridge.state.value
        if (current !is RecorderState.Idle && current !is RecorderState.Error &&
            current !is RecorderState.Saved && current !is RecorderState.Interrupted
        ) {
            RecorderBridge.emitError("COMMAND_INVALID_STATE", "start rejected while ${current.kind}", false)
            return
        }
        val projectionData = intent.getParcelableExtraCompat<Intent>(EXTRA_PROJECTION_DATA)
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Int.MIN_VALUE)
        if (projectionData == null || resultCode == Int.MIN_VALUE) {
            RecorderBridge.setState(RecorderState.Error("PROJECTION_REQUIRED", "capture consent missing", true))
            return
        }
        val codecTag = intent.getStringExtra(EXTRA_CODEC) ?: "h264"
        val codec = VideoCodecKind.fromTag(codecTag) ?: VideoCodecKind.H264
        val audioSourceTag = intent.getStringExtra(EXTRA_AUDIO_SOURCE) ?: AudioSourceKind.NONE.mediaStoreTag
        val audioSource = AudioSourceKind.entries.firstOrNull { it.mediaStoreTag == audioSourceTag } ?: AudioSourceKind.NONE
        val profileLabel = intent.getStringExtra(EXTRA_PROFILE_LABEL) ?: "custom profile"
        val width = intent.getIntExtra(EXTRA_WIDTH, 0)
        val height = intent.getIntExtra(EXTRA_HEIGHT, 0)
        val fps = intent.getIntExtra(EXTRA_FPS, 30)
        val videoBitrate = intent.getLongExtra(EXTRA_VIDEO_BITRATE, 0L)
        val audioBitrate = intent.getLongExtra(EXTRA_AUDIO_BITRATE, 0L)
        val config = RecordingConfig(width, height, fps, videoBitrate, audioBitrate, codec, false, false)
        val capabilities = CapabilityProbe.probe(this)
        val validationError = CapabilityProbe.validate(config, capabilities)
        if (validationError != null) {
            RecorderBridge.setState(RecorderState.Error(validationError.code, validationError.message, true))
            return
        }
        storageWarned = false
        storageStopTriggered = false
        RecorderBridge.setState(RecorderState.Preparing(profileLabel))
        val serviceTypes = if (audioSource == AudioSourceKind.MICROPHONE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(false), serviceTypes)
        RecorderBridge.setState(RecorderState.Starting(profileLabel))
        val newEngine = RecordingEngine(
            context = applicationContext,
            resultCode = resultCode,
            projectionData = projectionData,
            config = config,
            audioSource = audioSource,
            profileLabel = profileLabel
        )
        engine = newEngine
        val startedAt = System.currentTimeMillis()
        val startOutcome = newEngine.start()
        if (startOutcome.isFailure) {
            runCatching { newEngine.release() }
            engine = null
            RecorderBridge.setTelemetry(null)
            RecorderBridge.setState(
                RecorderState.Error(
                    "ENGINE_START_FAILED",
                    startOutcome.exceptionOrNull()?.message ?: "engine failed to start",
                    true
                )
            )
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        RecorderBridge.setState(RecorderState.Recording(startedAt, 0L, 0.0, 0, 1, audioSource.mediaStoreTag))
        if (android.provider.Settings.canDrawOverlays(this)) {
            runCatching { startService(Intent(this, BubbleService::class.java)) }
            overlayServiceRunning = true
        }
        startTelemetryLoop(newEngine, audioSource)
    }

    private fun handlePause() {
        val current = RecorderBridge.state.value
        if (current !is RecorderState.Recording) {
            RecorderBridge.emitError("COMMAND_INVALID_STATE", "pause rejected while ${current.kind}", false)
            return
        }
        val activeEngine = engine ?: return
        runCatching { activeEngine.closeSegment() }
        RecorderBridge.setState(
            RecorderState.Paused(
                startedAtEpochMs = current.startedAtEpochMs,
                elapsedMs = activeEngine.totalRecordedMs(),
                droppedFrames = activeEngine.droppedFrames(),
                segmentCount = activeEngine.segmentCount(),
                audioSource = current.audioSource
            )
        )
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(true), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
    }

    private fun handleResume() {
        val current = RecorderBridge.state.value
        if (current !is RecorderState.Paused) {
            RecorderBridge.emitError("COMMAND_INVALID_STATE", "resume rejected while ${current.kind}", false)
            return
        }
        val activeEngine = engine ?: return
        val openOutcome = activeEngine.openSegment()
        if (openOutcome.isFailure) {
            runCatching { activeEngine.release() }
            engine = null
            RecorderBridge.setState(
                RecorderState.Error(
                    "SEGMENT_OPEN_FAILED",
                    openOutcome.exceptionOrNull()?.message ?: "segment could not be opened",
                    false
                )
            )
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        RecorderBridge.setState(
            RecorderState.Recording(
                startedAtEpochMs = current.startedAtEpochMs,
                elapsedMs = activeEngine.totalRecordedMs(),
                fps = 0.0,
                droppedFrames = activeEngine.droppedFrames(),
                segmentCount = activeEngine.segmentCount(),
                audioSource = current.audioSource
            )
        )
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(false), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
    }

    private fun handleStop() {
        val current = RecorderBridge.state.value
        val activeEngine = engine
        if (activeEngine == null) {
            if (current is RecorderState.Idle) return
            if (current is RecorderState.Saved || current is RecorderState.Error) return
            RecorderBridge.emitError("COMMAND_INVALID_STATE", "stop ignored while ${current.kind}", false)
            return
        }
        if (current is RecorderState.Recording || current is RecorderState.Starting) {
            runCatching { activeEngine.closeSegment() }
        }
        val elapsed = activeEngine.totalRecordedMs()
        RecorderBridge.setState(RecorderState.Stopping(elapsed))
        val segmentCount = activeEngine.segmentCount()
        if (segmentCount == 0) {
            runCatching { activeEngine.release() }
            engine = null
            RecorderBridge.setTelemetry(null)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            RecorderBridge.setState(
                RecorderState.Error(
                    "NO_CONTENT",
                    "session ended before any frame was encoded",
                    true
                )
            )
            return
        }
        RecorderBridge.setState(RecorderState.Finalizing(segmentCount))
        val finalizeOutcome = activeEngine.finalize()
        runCatching { activeEngine.release() }
        engine = null
        RecorderBridge.setTelemetry(null)
        telemetryJob?.cancel()
        telemetryJob = null
        if (overlayServiceRunning) {
            runCatching { stopService(Intent(this, BubbleService::class.java)) }
            overlayServiceRunning = false
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        if (finalizeOutcome.isFailure) {
            RecorderBridge.setState(
                RecorderState.Error(
                    "FINALIZE_FAILED",
                    finalizeOutcome.exceptionOrNull()?.message ?: "recording could not be finalized",
                    false
                )
            )
            return
        }
        val saved = finalizeOutcome.getOrThrow()
        RecorderBridge.setState(
            RecorderState.Saved(
                uri = saved.uri,
                durationMs = saved.durationMs,
                sizeBytes = saved.sizeBytes,
                width = saved.width,
                height = saved.height,
                fps = saved.fps,
                codecTag = saved.codecTag,
                audioTag = saved.audioTag,
                segmentCount = saved.segmentCount
            )
        )
    }

    private fun startTelemetryLoop(activeEngine: RecordingEngine, audioSource: AudioSourceKind) {
        telemetryJob?.cancel()
        telemetryJob = scope.launch {
            var lastFrames = 0L
            while (isActive && engine === activeEngine) {
                val frames = activeEngine.framesEncoded()
                val fps = ((frames - lastFrames) * 2).toDouble().coerceAtLeast(0.0)
                lastFrames = frames
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                val thermalStatus = powerManager.getCurrentThermalStatus().toInt()
                val thermalHeadroom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    runCatching { powerManager.getThermalHeadroom(10).toDouble() }.getOrNull()
                } else {
                    null
                }
                val telemetry = RecorderTelemetry(
                    fps = fps,
                    droppedFrames = activeEngine.droppedFrames(),
                    thermalStatus = thermalStatus,
                    thermalHeadroom = thermalHeadroom,
                    elapsedMs = activeEngine.totalRecordedMs(),
                    segmentCount = activeEngine.segmentCount(),
                    activePipeline = activeEngine.activePipeline(),
                    audioSource = audioSource.mediaStoreTag
                )
                RecorderBridge.setTelemetry(telemetry)
                monitorStorage(activeEngine)
                val state = RecorderBridge.state.value
                if (state is RecorderState.Recording) {
                    RecorderBridge.setState(
                        state.copy(
                            elapsedMs = telemetry.elapsedMs,
                            fps = telemetry.fps,
                            droppedFrames = telemetry.droppedFrames,
                            segmentCount = telemetry.segmentCount
                        )
                    )
                }
                delay(500)
            }
        }
    }

    private fun monitorStorage(activeEngine: RecordingEngine) {
        val freeBytes = CapabilityProbe.measureFreeStorage(this)
        if (freeBytes <= 0L) return
        val combinedBitrate = activeEngine.combinedBitrateBps()
        val oneMinuteReserveBytes = combinedBitrate * 60L * 11L / 10L
        val tenSecondsReserveBytes = combinedBitrate * 10L * 11L / 10L
        if (freeBytes > oneMinuteReserveBytes) return
        if (!storageWarned) {
            storageWarned = true
            RecorderBridge.emitError(
                "STORAGE_LOW",
                "free storage is below one minute of recording reserve",
                true
            )
        }
        if (freeBytes <= tenSecondsReserveBytes && !storageStopTriggered) {
            storageStopTriggered = true
            RecorderBridge.emitError(
                "STORAGE_CRITICAL",
                "session is being stopped and finalized because storage is almost full",
                false
            )
            startService(Intent(this, ScreenRecordService::class.java).setAction(ACTION_STOP))
        }
    }

    private fun buildNotification(paused: Boolean): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen recording",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val toggleAction = if (paused) ACTION_RESUME else ACTION_PAUSE
        val toggleIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ScreenRecordService::class.java).setAction(toggleAction),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, ScreenRecordService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(if (paused) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
            .setContentTitle("BexxCord")
            .setContentText(if (paused) "Recording paused" else "Recording in progress")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(
                        this,
                        if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause
                    ),
                    if (paused) "Resume" else "Pause",
                    toggleIntent
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(this, android.R.drawable.ic_delete),
                    "Stop",
                    stopIntent
                ).build()
            )
            .build()
    }
}

data class SavedOutcome(
    val uri: String,
    val durationMs: Long,
    val sizeBytes: Long,
    val width: Int,
    val height: Int,
    val fps: Int,
    val codecTag: String,
    val audioTag: String,
    val segmentCount: Int
)

private class RecordingEngine(
    private val context: Context,
    private val resultCode: Int,
    private val projectionData: Intent,
    private val config: RecordingConfig,
    private val audioSource: AudioSourceKind,
    private val profileLabel: String
) {
    private var projection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var muxer: MediaMuxer? = null
    private var videoEncoder: MediaCodec? = null
    private var audioEncoder: MediaCodec? = null
    private var videoSurface: Surface? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var audioRecord: AudioRecord? = null
    private var drainThread: Thread? = null
    private var audioThread: Thread? = null
    private val segmentDir = File(context.cacheDir, "bexxcord_segments_${System.currentTimeMillis()}")
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1
    private var muxerStarted = false
    private var audioConfigured = false
    private var segmentOpenRealtime = 0L
    private var accumulatedMs = 0L
    @Volatile
    private var running = false
    @Volatile
    private var audioRunning = false
    @Volatile
    private var framesEncoded = 0L
    @Volatile
    private var droppedFrames = 0
    @Volatile
    private var videoOffsetUs = 0L
    @Volatile
    private var audioOffsetUs = 0L
    @Volatile
    private var currentSegmentVideoMaxPtsUs = 0L
    @Volatile
    private var currentSegmentAudioMaxPtsUs = 0L
    @Volatile
    private var currentSegmentFile: File? = null

    fun start(): Result<Unit> = runCatching {
        segmentDir.mkdirs()
        val projectionManager = context.getSystemService(MediaProjectionManager::class.java)
        val activeProjection = projectionManager.getMediaProjection(resultCode, projectionData)
        projection = activeProjection
        val callback = object : MediaProjection.Callback() {
            override fun onStop() {
                RecorderBridge.setState(RecorderState.Interrupted("projection_stopped"))
                val intent = Intent(context, ScreenRecordService::class.java)
                    .setAction(ScreenRecordService.ACTION_STOP)
                context.startService(intent)
            }
        }
        projectionCallback = callback
        activeProjection.registerCallback(
            callback,
            android.os.Handler(android.os.Looper.getMainLooper())
        )
        openSegment().getOrThrow()
    }

    @Volatile
    private var audioActiveInSession = false

    fun openSegment(): Result<Unit> = runCatching {
        val segmentFile = File(segmentDir, "segment_${segmentCount().coerceAtMost(99)}.mp4")
        currentSegmentFile = segmentFile
        val newMuxer = MediaMuxer(segmentFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxer = newMuxer
        videoTrackIndex = -1
        audioTrackIndex = -1
        muxerStarted = false
        currentSegmentVideoMaxPtsUs = 0L
        currentSegmentAudioMaxPtsUs = 0L
        videoEncoder = MediaCodec.createEncoderByType(config.codec.mimeType)
        val videoFormat = MediaFormat.createVideoFormat(config.codec.mimeType, config.width, config.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, config.videoBitrateBps.toInt())
            setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        videoEncoder?.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        videoSurface = videoEncoder?.createInputSurface()
        videoEncoder?.start()
        if (audioSource != AudioSourceKind.NONE) {
            audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            val audioFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 2).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, config.audioBitrateBps.toInt())
            }
            audioEncoder?.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            audioEncoder?.start()
            val recordOutcome = createAudioRecord(activeProjection = projection)
            if (recordOutcome.isSuccess) {
                audioRecord = recordOutcome.getOrThrow()
                audioRecord?.startRecording()
                audioConfigured = true
                audioActiveInSession = true
            } else {
                audioEncoder?.let { runCatching { it.release() } }
                audioEncoder = null
                audioConfigured = false
                if (audioSource == AudioSourceKind.SYSTEM_PLAYBACK) {
                    RecorderBridge.emitError(
                        "AUDIO_SYSTEM_UNAVAILABLE",
                        recordOutcome.exceptionOrNull()?.message ?: "system audio capture unavailable",
                        true
                    )
                }
            }
        }
        val densityDpi = context.resources.displayMetrics.densityDpi
        virtualDisplay = projection?.createVirtualDisplay(
            "bexxcord_display_${segmentCount()}",
            config.width,
            config.height,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            videoSurface,
            null,
            null
        )
        if (virtualDisplay == null) {
            throw IOException("virtual_display_creation_failed")
        }
        segmentOpenRealtime = SystemClock.elapsedRealtime()
        running = true
        drainThread = Thread { drainLoop() }.also { it.start() }
        if (audioConfigured) {
            audioRunning = true
            audioThread = Thread { audioLoop() }.also { it.start() }
        }
        if (audioSource != AudioSourceKind.NONE && !audioConfigured && audioEncoder == null) {
            RecorderBridge.emitError(
                "AUDIO_DROPPED",
                "recording continues without audio track",
                true
            )
        }
    }

    private fun createAudioRecord(activeProjection: MediaProjection?): Result<AudioRecord> = runCatching {
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuffer <= 0) {
            throw IOException("audio_min_buffer_unavailable")
        }
        val builder = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(minBuffer * 4)
        if (audioSource == AudioSourceKind.SYSTEM_PLAYBACK) {
            val projectionForCapture = activeProjection ?: throw IOException("projection_required_for_playback_capture")
            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(projectionForCapture)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            builder.setAudioPlaybackCaptureConfig(captureConfig)
        } else {
            builder.setAudioSource(MediaRecorder.AudioSource.MIC)
        }
        val record = builder.build()
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            runCatching { record.release() }
            throw IOException("audio_record_init_failed")
        }
        record
    }

    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()
        var videoEos = false
        var audioEos = !audioConfigured
        while (!videoEos || !audioEos) {
            val encoder = videoEncoder
            if (!videoEos && encoder != null) {
                videoEos = drainEncoder(encoder, info, true)
            } else if (encoder == null) {
                videoEos = true
            }
            val audioEngine = audioEncoder
            if (!audioEos && audioEngine != null) {
                audioEos = drainEncoder(audioEngine, info, false)
            } else if (audioEngine == null) {
                audioEos = true
            }
        }
    }

    private fun drainEncoder(codec: MediaCodec, info: MediaCodec.BufferInfo, video: Boolean): Boolean {
        val index = codec.dequeueOutputBuffer(info, 10_000L)
        if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return false
        if (index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) return false
        if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            maybeStartMuxer(codec.outputFormat, video)
            return false
        }
        if (index >= 0) {
            val buffer = codec.getOutputBuffer(index)
            if (info.size > 0 && buffer != null && muxerStarted) {
                val track = if (video) videoTrackIndex else audioTrackIndex
                if (track >= 0) {
                    if (video) {
                        framesEncoded += 1
                        if (info.presentationTimeUs > currentSegmentVideoMaxPtsUs) {
                            currentSegmentVideoMaxPtsUs = info.presentationTimeUs
                        }
                    } else {
                        if (info.presentationTimeUs > currentSegmentAudioMaxPtsUs) {
                            currentSegmentAudioMaxPtsUs = info.presentationTimeUs
                        }
                    }
                    runCatching { muxer?.writeSampleData(track, buffer, info) }
                } else {
                    droppedFrames += 1
                }
            } else if (info.size > 0 && !muxerStarted) {
                droppedFrames += 1
            }
            val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            codec.releaseOutputBuffer(index, false)
            return eos
        }
        return false
    }

    private fun maybeStartMuxer(format: MediaFormat, video: Boolean) {
        val target = muxer ?: return
        if (video) {
            if (videoTrackIndex == -1) {
                videoTrackIndex = runCatching { target.addTrack(format) }.getOrDefault(-1)
            }
        } else {
            if (audioTrackIndex == -1) {
                audioTrackIndex = runCatching { target.addTrack(format) }.getOrDefault(-1)
            }
        }
        val audioExpected = audioConfigured
        val videoReady = videoTrackIndex >= 0
        val audioReady = audioTrackIndex >= 0 || !audioExpected
        if (!muxerStarted && videoReady && audioReady) {
            runCatching {
                target.start()
                muxerStarted = true
            }
        }
    }

    private fun audioLoop() {
        val record = audioRecord ?: return
        val codec = audioEncoder ?: return
        val pcmBuffer = ShortArray(2048)
        var totalFrames = 0L
        while (audioRunning) {
            val read = runCatching { record.read(pcmBuffer, 0, pcmBuffer.size) }.getOrDefault(0)
            if (read < 0) break
            if (read == 0) continue
            val inputIndex = runCatching { codec.dequeueInputBuffer(10_000L) }.getOrDefault(-1)
            if (inputIndex < 0) {
                continue
            }
            val inputBuffer = codec.getInputBuffer(inputIndex) ?: continue
            inputBuffer.clear()
            var written = 0
            while (written < read) {
                inputBuffer.putShort(pcmBuffer[written])
                written += 1
            }
            val ptsUs = totalFrames * 1_000_000L / SAMPLE_RATE
            runCatching { codec.queueInputBuffer(inputIndex, 0, read * 2, ptsUs, 0) }
            totalFrames += read / 2
        }
        runCatching { codec.signalEndOfInputStream() }
    }

    fun closeSegment() {
        val activeEncoder = videoEncoder
        val activeAudioEncoder = audioEncoder
        running = false
        audioRunning = false
        runCatching { activeEncoder?.signalEndOfInputStream() }
        runCatching { activeAudioEncoder?.signalEndOfInputStream() }
        drainThread?.join(3000)
        audioThread?.join(3000)
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { audioRecord?.release() }
        audioRecord = null
        runCatching { videoEncoder?.stop() }
        runCatching { videoEncoder?.release() }
        videoEncoder = null
        videoSurface?.release()
        videoSurface = null
        runCatching { audioEncoder?.stop() }
        runCatching { audioEncoder?.release() }
        audioEncoder = null
        drainThread = null
        audioThread = null
        if (muxerStarted) {
            runCatching { muxer?.stop() }
            accumulatedMs += (SystemClock.elapsedRealtime() - segmentOpenRealtime).coerceAtLeast(0L)
        } else {
            currentSegmentFile?.delete()
        }
        runCatching { muxer?.release() }
        muxer = null
        audioConfigured = false
        muxerStarted = false
        videoTrackIndex = -1
        audioTrackIndex = -1
    }

    fun finalize(): Result<SavedOutcome> = runCatching {
        if (running || audioRunning) {
            closeSegment()
        }
        val stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"))
        val title = "BexxCord_${stamp}"
        val audioTag = if (audioActiveInSession) {
            audioSource.mediaStoreTag
        } else {
            AudioSourceKind.NONE.mediaStoreTag
        }
        val display = buildDisplayName(title, config.codec.mediaStoreTag, audioTag)
        val uri = insertPending(display)
        val resolver = context.contentResolver
        if (segmentCount() == 1) {
            resolver.openOutputStream(uri)?.use { out ->
                segmentFiles().first().inputStream().use { it.copyTo(out) }
            } ?: throw IOException("mediastore_stream_unavailable")
        } else {
            resolver.openAssetFileDescriptor(uri, "rw")?.use { assetFd ->
                stitchSegments(assetFd.fileDescriptor)
            } ?: throw IOException("mediastore_stream_unavailable")
        }
        val durationMs = (maxOf(videoOffsetUs, audioOffsetUs) / 1000L).coerceAtLeast(accumulatedMs)
        markFinalized(uri, durationMs)
        val sizeBytes = querySize(uri)
        val outcome = SavedOutcome(
            uri = uri.toString(),
            durationMs = durationMs,
            sizeBytes = sizeBytes,
            width = config.width,
            height = config.height,
            fps = config.fps,
            codecTag = config.codec.mediaStoreTag,
            audioTag = audioTag,
            segmentCount = segmentCount()
        )
        runCatching { segmentDir.deleteRecursively() }
        outcome
    }

    private fun buildDisplayName(title: String, codecTag: String, audioTag: String): String =
        RecordingStore.buildName(title, codecTag, audioTag)

    private fun stitchSegments(fd: FileDescriptor) {
        val muxer = MediaMuxer(fd, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val extractor = MediaExtractor()
        val buffer = ByteBuffer.allocateDirect(4 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()
        var videoTrack = -1
        var audioTrack = -1
        try {
            segmentFiles().forEachIndexed { index, file ->
                extractor.setDataSource(file.absolutePath)
                if (index == 0) {
                    for (trackIndex in 0 until extractor.trackCount) {
                        val format = extractor.getTrackFormat(trackIndex)
                        val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                        if (mime.startsWith("video/") && videoTrack == -1) {
                            videoTrack = muxer.addTrack(format)
                        }
                        if (mime.startsWith("audio/") && audioTrack == -1) {
                            audioTrack = muxer.addTrack(format)
                        }
                    }
                    if (videoTrack == -1) {
                        throw IOException("video_track_missing_in_segment")
                    }
                    muxer.start()
                }
                for (trackIndex in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(trackIndex)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    val target = when {
                        mime.startsWith("video/") && videoTrack >= 0 -> videoTrack
                        mime.startsWith("audio/") && audioTrack >= 0 -> audioTrack
                        else -> -1
                    }
                    if (target == -1) continue
                    extractor.selectTrack(trackIndex)
                    var maxPts = 0L
                    while (true) {
                        val sampleSize = runCatching { extractor.readSampleData(buffer, 0) }.getOrDefault(-1)
                        if (sampleSize < 0) break
                        val sampleTime = extractor.sampleTime
                        val offset = if (mime.startsWith("video/")) videoOffsetUs else audioOffsetUs
                        val flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                            MediaCodec.BUFFER_FLAG_SYNC_FRAME
                        } else {
                            0
                        }
                        info.set(0, sampleSize, sampleTime + offset, flags)
                        runCatching { muxer.writeSampleData(target, buffer, info) }
                        if (sampleTime > maxPts) {
                            maxPts = sampleTime
                        }
                        extractor.advance()
                    }
                    if (mime.startsWith("video/")) {
                        videoOffsetUs += maxPts + 1000
                    } else {
                        audioOffsetUs += maxPts + 1000
                    }
                    extractor.unselectTrack(trackIndex)
                }
            }
        } finally {
            runCatching { muxer.stop() }
            muxer.release()
            runCatching { extractor.release() }
        }
    }

    private fun insertPending(displayName: String): android.net.Uri {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/BexxCord")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        return context.contentResolver.insert(
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            values
        ) ?: throw IOException("mediastore_insert_failed")
    }

    private fun markFinalized(uri: android.net.Uri, durationMs: Long) {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.IS_PENDING, 0)
            put(MediaStore.Video.Media.DURATION, durationMs)
            put(MediaStore.Video.Media.WIDTH, config.width)
            put(MediaStore.Video.Media.HEIGHT, config.height)
        }
        context.contentResolver.update(uri, values, null, null)
    }

    private fun querySize(uri: android.net.Uri): Long {
        val projection = arrayOf(MediaStore.Video.Media.SIZE)
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getLong(0)
            }
        }
        return 0L
    }

    private fun segmentFiles(): List<File> = segmentDir.listFiles()
        ?.filter { it.isFile && it.extension == "mp4" }
        ?.sortedBy { it.name }
        ?: emptyList()

    fun segmentCount(): Int = segmentFiles().size

    fun framesEncoded(): Long = framesEncoded

    fun droppedFrames(): Int = droppedFrames

    fun totalRecordedMs(): Long = accumulatedMs

    fun activePipeline(): String = "MediaCodec+MediaMuxer"

    fun combinedBitrateBps(): Long = config.videoBitrateBps + config.audioBitrateBps

    fun profile(): String = profileLabel

    fun release() {
        closeSegment()
        projectionCallback?.let { callback ->
            runCatching { projection?.unregisterCallback(callback) }
        }
        runCatching { projection?.stop() }
        projection = null
        runCatching { segmentDir.deleteRecursively() }
    }
}

private fun <T : android.os.Parcelable> Intent.getParcelableExtraCompat(name: String): T? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(name, T::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(name) as? T
    }
