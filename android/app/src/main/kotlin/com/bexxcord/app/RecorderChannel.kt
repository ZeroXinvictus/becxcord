package com.bexxcord.app

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

data class ProjectionGrant(val resultCode: Int, val data: Intent)

object RecorderBridge {
    val state = kotlinx.coroutines.flow.MutableStateFlow<RecorderState>(RecorderState.Idle)
    val telemetry = kotlinx.coroutines.flow.MutableStateFlow<RecorderTelemetry?>(null)
    val errors = kotlinx.coroutines.flow.MutableStateFlow<RecorderErrorEvent?>(null)

    @Volatile
    var grant: ProjectionGrant? = null

    fun setState(next: RecorderState) {
        state.value = next
    }

    fun setTelemetry(next: RecorderTelemetry?) {
        telemetry.value = next
    }

    fun emitError(code: String, message: String, recoverable: Boolean) {
        errors.value = RecorderErrorEvent(code, message, recoverable, System.currentTimeMillis())
    }

    fun consumeGrant(): ProjectionGrant? {
        val current = grant
        grant = null
        return current
    }
}

private val Context.settingsStore by preferencesDataStore(name = "bexxcord_settings")

object PrefsRepository {
    private val MIC = booleanPreferencesKey("mic_enabled")
    private val SYSTEM = booleanPreferencesKey("system_audio_enabled")
    private val WIDTH = intPreferencesKey("width")
    private val HEIGHT = intPreferencesKey("height")
    private val FPS = intPreferencesKey("fps")
    private val VIDEO_BITRATE = longPreferencesKey("video_bitrate")
    private val AUDIO_BITRATE = longPreferencesKey("audio_bitrate")
    private val CODEC = stringPreferencesKey("codec")
    private val COUNTDOWN = booleanPreferencesKey("countdown_enabled")

    suspend fun read(context: Context): Map<String, Any?> {
        val prefs = context.settingsStore.data.first()
        return mapOf(
            "micEnabled" to (prefs[MIC] ?: true),
            "systemAudioEnabled" to (prefs[SYSTEM] ?: true),
            "width" to (prefs[WIDTH] ?: 0),
            "height" to (prefs[HEIGHT] ?: 0),
            "fps" to (prefs[FPS] ?: 30),
            "videoBitrateBps" to (prefs[VIDEO_BITRATE] ?: 12_000_000L),
            "audioBitrateBps" to (prefs[AUDIO_BITRATE] ?: 128_000L),
            "codec" to (prefs[CODEC] ?: "h264"),
            "countdownEnabled" to (prefs[COUNTDOWN] ?: true)
        )
    }

    suspend fun writeMic(context: Context, value: Boolean) {
        context.settingsStore.edit { it[MIC] = value }
    }

    suspend fun writeSystemAudio(context: Context, value: Boolean) {
        context.settingsStore.edit { it[SYSTEM] = value }
    }

    suspend fun writeCountdown(context: Context, value: Boolean) {
        context.settingsStore.edit { it[COUNTDOWN] = value }
    }

    suspend fun writeProfile(
        context: Context,
        width: Int,
        height: Int,
        fps: Int,
        videoBitrateBps: Long,
        audioBitrateBps: Long,
        codecTag: String
    ) {
        context.settingsStore.edit {
            it[WIDTH] = width
            it[HEIGHT] = height
            it[FPS] = fps
            it[VIDEO_BITRATE] = videoBitrateBps
            it[AUDIO_BITRATE] = audioBitrateBps
            it[CODEC] = codecTag
        }
    }
}

object RecordingStore {

    fun list(context: Context): List<Map<String, Any?>> {
        val resolver = context.contentResolver
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.DATE_ADDED
        )
        val selection = "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?"
        val args = arrayOf("Movies/BexxCord/%")
        val sortOrder = "${MediaStore.Video.Media.DATE_ADDED} DESC"
        val entries = mutableListOf<Map<String, Any?>>()
        resolver.query(collection, projection, selection, args, sortOrder)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val rawName = cursor.getString(1) ?: continue
                val parsed = parseName(rawName)
                entries.add(
                    mapOf(
                        "uri" to ContentUris.withAppendedId(collection, id).toString(),
                        "title" to parsed.base,
                        "durationMs" to cursor.getLong(2),
                        "sizeBytes" to cursor.getLong(3),
                        "width" to cursor.getInt(4),
                        "height" to cursor.getInt(5),
                        "createdAtMs" to cursor.getLong(6) * 1000L,
                        "codecTag" to parsed.codecTag,
                        "audioTag" to parsed.audioTag
                    )
                )
            }
        }
        return entries
    }

    fun delete(context: Context, uri: String): Boolean {
        return runCatching {
            context.contentResolver.delete(Uri.parse(uri), null, null) > 0
        }.getOrDefault(false)
    }

    fun thumbnail(context: Context, uri: String, width: Int, height: Int): ByteArray? {
        val bitmap = runCatching {
            context.contentResolver.loadThumbnail(Uri.parse(uri), android.util.Size(width, height), null)
        }.getOrNull() ?: return null
        val output = java.io.ByteArrayOutputStream()
        val encoded = bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, output)
        bitmap.recycle()
        if (!encoded) return null
        return output.toByteArray()
    }

    fun captureFrame(context: Context, uri: String, positionMs: Long): Map<String, Any?>? {
        val frame = runCatching {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, Uri.parse(uri))
                retriever.getFrameAtTime(
                    positionMs * 1000L,
                    android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                )
            } finally {
                runCatching { retriever.release() }
            }
        }.getOrNull() ?: return null
        val widthPx = frame.width
        val heightPx = frame.height
        val output = java.io.ByteArrayOutputStream()
        val encoded = frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, output)
        frame.recycle()
        if (!encoded) return null
        val stamp = java.time.LocalDateTime.now()
            .format(java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"))
        val values = android.content.ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "BexxCord_Frame_${stamp}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/BexxCord")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val target = context.contentResolver.insert(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            values
        ) ?: return null
        val stream = context.contentResolver.openOutputStream(target) ?: return null
        val written = runCatching { stream.use { it.write(output.toByteArray()) } }.isSuccess
        if (!written) {
            runCatching { context.contentResolver.delete(target, null, null) }
            return null
        }
        val finalized = android.content.ContentValues().apply {
            put(MediaStore.Images.Media.IS_PENDING, 0)
            put(MediaStore.Images.Media.WIDTH, widthPx)
            put(MediaStore.Images.Media.HEIGHT, heightPx)
        }
        context.contentResolver.update(target, finalized, null, null)
        return mapOf(
            "uri" to target.toString(),
            "width" to widthPx,
            "height" to heightPx,
            "sourcePositionMs" to positionMs
        )
    }

    fun rename(context: Context, uri: String, newTitle: String): Boolean {
        val sanitized = newTitle.trim().replace(Regex("[^A-Za-z0-9 _-]"), "").take(64)
        if (sanitized.isEmpty()) return false
        val existing = lookupTags(context, uri) ?: return false
        val display = buildName(sanitized, existing.first, existing.second)
        val values = android.content.ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, display)
        }
        return runCatching {
            context.contentResolver.update(Uri.parse(uri), values, null, null) > 0
        }.getOrDefault(false)
    }

    fun buildName(title: String, codecTag: String, audioTag: String): String =
        if (title.endsWith(".mp4")) title else "${title}_${codecTag}_${audioTag}.mp4"

    private data class ParsedName(val base: String, val codecTag: String, val audioTag: String)

    private fun parseName(raw: String): ParsedName {
        val base = rawName.removeSuffix(".mp4")
        val parts = base.split("_")
        val codecTag = parts.firstOrNull { it == "h264" || it == "h265" } ?: "h264"
        val audioTag = parts.firstOrNull { it == "sys" || it == "mic" || it == "mute" } ?: "mute"
        val title = parts.filterNot { it == codecTag || it == audioTag }.joinToString("_")
        return ParsedName(title.ifEmpty { "recording" }, codecTag, audioTag)
    }

    private fun lookupTags(context: Context, uri: String): Pair<String, String>? {
        val parsed = runCatching {
            val projection = arrayOf(MediaStore.Video.Media.DISPLAY_NAME)
            context.contentResolver.query(Uri.parse(uri), projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull() ?: return null
        val name = parsed ?: return null
        val p = parseName(name)
        return p.codecTag to p.audioTag
    }
}

class RecorderChannel private constructor(
    private val activity: Activity,
    private val context: Context,
    messenger: BinaryMessenger,
    private val scope: CoroutineScope
) {
    companion object {
        private const val METHOD_CHANNEL = "bexxcord/recorder"
        private const val STATE_CHANNEL = "bexxcord/state"
        private const val TELEMETRY_CHANNEL = "bexxcord/telemetry"
        private const val ERROR_CHANNEL = "bexxcord/errors"
        private const val PROGRESS_CHANNEL = "bexxcord/recordingProgress"
        private const val REQUEST_PROJECTION = 7001
        private const val REQUEST_RUNTIME_PERMISSIONS = 7002

        private var instance: RecorderChannel? = null

        fun register(activity: Activity, messenger: BinaryMessenger) {
            if (instance != null) return
            val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
            instance = RecorderChannel(activity, activity.applicationContext, messenger, scope)
        }

        fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
            instance?.onActivityResult(requestCode, resultCode, data)
        }

        fun handlePermissionResult(permissions: Array<out String>, grantResults: IntArray) {
            instance?.onPermissionResult(permissions, grantResults)
        }

        fun detach() {
            instance = null
        }
    }

    private var projectionResult: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            scope.launch(Dispatchers.IO) {
                runCatching { dispatch(call, result) }
                    .onFailure { result.error("CHANNEL_FAILURE", it.message ?: "unknown", null) }
            }
        }
        bindEventChannel(messenger, STATE_CHANNEL, RecorderBridge.state) { it.toContractMap() }
        bindEventChannel(messenger, TELEMETRY_CHANNEL, RecorderBridge.telemetry.filterNotNull()) { it.toContractMap() }
        bindEventChannel(messenger, ERROR_CHANNEL, RecorderBridge.errors.filterNotNull()) { it.toContractMap() }
        bindEventChannel(messenger, PROGRESS_CHANNEL, RecorderBridge.state) { it.toContractMap() }
    }

    private fun <T> bindEventChannel(
        messenger: BinaryMessenger,
        name: String,
        flow: kotlinx.coroutines.flow.Flow<T>,
        transform: (T) -> Map<String, Any?>
    ) {
        EventChannel(messenger, name).setStreamHandler(object : EventChannel.StreamHandler {
            private var job: kotlinx.coroutines.Job? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                job = scope.launch {
                    flow.collect { value ->
                        events.success(transform(value))
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                job?.cancel()
                job = null
            }
        })
    }

    private suspend fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                val capabilities = CapabilityProbe.probe(context)
                result.success(
                    mapOf(
                        "notificationPermissionGranted" to capabilities.notificationPermissionGranted,
                        "overlayPermissionGranted" to capabilities.overlayPermissionGranted,
                        "microphonePermissionGranted" to hasPermission(Manifest.permission.RECORD_AUDIO)
                    )
                )
            }
            "requestRuntimePermissions" -> requestRuntimePermissions(result)
            "getCapabilities" -> result.success(CapabilityProbe.probe(context).toContractMap())
            "getPreferences" -> result.success(PrefsRepository.read(context))
            "setMicEnabled" -> setAudioPreference(call, result) { ctx, value -> PrefsRepository.writeMic(ctx, value) }
            "setSystemAudioEnabled" -> setAudioPreference(call, result) { ctx, value -> PrefsRepository.writeSystemAudio(ctx, value) }
            "setCountdownEnabled" -> {
                val value = call.arguments as? Boolean
                if (value == null) {
                    result.error("INVALID_ARGUMENT", "boolean required", null)
                } else {
                    PrefsRepository.writeCountdown(context, value)
                    result.success(true)
                }
            }
            "saveProfile" -> saveProfile(call, result)
            "requestProjection" -> requestProjection(result)
            "startRecording" -> startRecording(call, result)
            "pauseRecording" -> sendCommand(ScreenRecordService.ACTION_PAUSE, result)
            "resumeRecording" -> sendCommand(ScreenRecordService.ACTION_RESUME, result)
            "stopRecording" -> sendCommand(ScreenRecordService.ACTION_STOP, result)
            "getRecordings" -> result.success(RecordingStore.list(context))
            "deleteRecording" -> {
                val uri = call.arguments as? String
                if (uri == null) {
                    result.error("INVALID_ARGUMENT", "uri required", null)
                } else {
                    result.success(RecordingStore.delete(context, uri))
                }
            }
            "renameRecording" -> {
                val args = call.arguments as? Map<*, *>
                val uri = args?.get("uri") as? String
                val title = args?.get("title") as? String
                if (uri == null || title == null) {
                    result.error("INVALID_ARGUMENT", "uri and title required", null)
                } else {
                    result.success(RecordingStore.rename(context, uri, title))
                }
            }
            "getRecordingThumbnail" -> {
                val uri = call.arguments as? String
                if (uri == null) {
                    result.error("INVALID_ARGUMENT", "uri required", null)
                } else {
                    result.success(RecordingStore.thumbnail(context, uri, 256, 144))
                }
            }
            "captureFrame" -> {
                val args = call.arguments as? Map<*, *>
                val uri = args?.get("uri") as? String
                val positionMs = when (val raw = args?.get("positionMs")) {
                    is Long -> raw
                    is Int -> raw.toLong()
                    else -> null
                }
                if (uri == null || positionMs == null) {
                    result.error("INVALID_ARGUMENT", "uri and positionMs required", null)
                } else {
                    val outcome = RecordingStore.captureFrame(context, uri, positionMs)
                    if (outcome == null) {
                        result.error("FRAME_CAPTURE_FAILED", "frame could not be extracted at that position", null)
                    } else {
                        result.success(outcome)
                    }
                }
            }
            "openOverlaySettings" -> {
                activity.runOnUiThread {
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:${activity.packageName}")
                        )
                    )
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun requestRuntimePermissions(result: MethodChannel.Result) {
        val wanted = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) {
            wanted.add(Manifest.permission.RECORD_AUDIO)
        }
        if (wanted.isEmpty()) {
            result.success(mapOf("notifications" to true, "microphone" to true))
            return
        }
        permissionResult = result
        activity.runOnUiThread {
            ActivityCompat.requestPermissions(activity, wanted.toTypedArray(), REQUEST_RUNTIME_PERMISSIONS)
        }
    }

    fun onPermissionResult(permissions: Array<out String>, grantResults: IntArray) {
        val pending = permissionResult ?: return
        permissionResult = null
        val micGranted = permissions.indexOfFirst { it == Manifest.permission.RECORD_AUDIO }
            .let { index -> index < 0 || grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED }
        val notificationsGranted = permissions.indexOfFirst { it == Manifest.permission.POST_NOTIFICATIONS }
            .let { index -> index < 0 || grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED }
        pending.success(mapOf("microphone" to micGranted, "notifications" to notificationsGranted))
    }

    private fun requestProjection(result: MethodChannel.Result) {
        val manager = context.getSystemService(MediaProjectionManager::class.java) ?: run {
            result.error("PROJECTION_UNAVAILABLE", "MediaProjectionManager missing", null)
            return
        }
        if (projectionResult != null) {
            result.error("PROJECTION_REQUEST_IN_FLIGHT", "consent dialog already open", null)
            return
        }
        projectionResult = result
        activity.runOnUiThread {
            activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_PROJECTION)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PROJECTION) return
        val pending = projectionResult ?: return
        projectionResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            RecorderBridge.grant = ProjectionGrant(resultCode, data)
            pending.success(mapOf("granted" to true, "reason" to null as String?))
        } else {
            pending.success(mapOf("granted" to false, "reason" to "consent_denied"))
        }
    }

    private suspend fun setAudioPreference(
        call: MethodCall,
        result: MethodChannel.Result,
        writer: suspend (Context, Boolean) -> Unit
    ) {
        val value = (call.arguments as? Boolean) ?: run {
            result.error("INVALID_ARGUMENT", "boolean required", null)
            return
        }
        val state = RecorderBridge.state.value
        if (state is RecorderState.Recording || state is RecorderState.Paused || state is RecorderState.Starting || state is RecorderState.Stopping) {
            result.success(mapOf("applied" to false, "errorCode" to "CONFIG_LOCKED_WHILE_RECORDING"))
            return
        }
        if (value && !hasPermission(Manifest.permission.RECORD_AUDIO)) {
            result.success(mapOf("applied" to false, "errorCode" to "PERMISSION_MIC_DENIED"))
            return
        }
        writer(context, value)
        result.success(mapOf("applied" to true, "errorCode" to null as String?))
    }

    private suspend fun saveProfile(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run {
            result.error("INVALID_ARGUMENT", "profile map required", null)
            return
        }
        val width = (args["width"] as? Int) ?: 0
        val height = (args["height"] as? Int) ?: 0
        val fps = (args["fps"] as? Int) ?: 30
        val videoBitrate = (args["videoBitrateBps"] as? Long) ?: 12_000_000L
        val audioBitrate = (args["audioBitrateBps"] as? Long) ?: 128_000L
        val codecTag = (args["codec"] as? String) ?: "h264"
        PrefsRepository.writeProfile(context, width, height, fps, videoBitrate, audioBitrate, codecTag)
        result.success(true)
    }

    private suspend fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        val state = RecorderBridge.state.value
        if (state !is RecorderState.Idle && state !is RecorderState.Error && state !is RecorderState.Saved && state !is RecorderState.Interrupted) {
            result.success(
                mapOf(
                    "accepted" to false,
                    "errorCode" to "COMMAND_INVALID_STATE",
                    "errorMessage" to "recorder is busy in ${state.kind}"
                )
            )
            return
        }
        val grant = RecorderBridge.consumeGrant() ?: run {
            result.success(
                mapOf(
                    "accepted" to false,
                    "errorCode" to "PROJECTION_REQUIRED",
                    "errorMessage" to "capture consent required before every session"
                )
            )
            return
        }
        val config = parseConfig(call.arguments) ?: run {
            result.success(
                mapOf(
                    "accepted" to false,
                    "errorCode" to "CONFIG_MALFORMED",
                    "errorMessage" to "recording configuration failed type checks"
                )
            )
            return
        }
        val capabilities = CapabilityProbe.probe(context)
        val validationError = CapabilityProbe.validate(config, capabilities)
        if (validationError != null) {
            result.success(
                mapOf(
                    "accepted" to false,
                    "errorCode" to validationError.code,
                    "errorMessage" to validationError.message
                )
            )
            return
        }
        val audioSource = resolveAudioSource(config, capabilities)
        val profileLabel = "${config.width}x${config.height}@${config.fps} ${config.codec.mediaStoreTag}"
        val intent = Intent(context, ScreenRecordService::class.java)
            .setAction(ScreenRecordService.ACTION_START)
            .putExtra(ScreenRecordService.EXTRA_RESULT_CODE, grant.resultCode)
            .putExtra(ScreenRecordService.EXTRA_PROJECTION_DATA, grant.data)
            .putExtra(ScreenRecordService.EXTRA_WIDTH, config.width)
            .putExtra(ScreenRecordService.EXTRA_HEIGHT, config.height)
            .putExtra(ScreenRecordService.EXTRA_FPS, config.fps)
            .putExtra(ScreenRecordService.EXTRA_VIDEO_BITRATE, config.videoBitrateBps)
            .putExtra(ScreenRecordService.EXTRA_AUDIO_BITRATE, config.audioBitrateBps)
            .putExtra(ScreenRecordService.EXTRA_CODEC, config.codec.mediaStoreTag)
            .putExtra(ScreenRecordService.EXTRA_AUDIO_SOURCE, audioSource.mediaStoreTag)
            .putExtra(ScreenRecordService.EXTRA_PROFILE_LABEL, profileLabel)
        ContextCompat.startForegroundService(context, intent)
        result.success(
            mapOf(
                "accepted" to true,
                "errorCode" to null as String?,
                "errorMessage" to null as String?
            )
        )
    }

    private fun resolveAudioSource(config: RecordingConfig, capabilities: RecorderCapabilities): AudioSourceKind {
        return when {
            config.systemAudioEnabled && capabilities.systemPlaybackSupported -> AudioSourceKind.SYSTEM_PLAYBACK
            config.micEnabled -> AudioSourceKind.MICROPHONE
            else -> AudioSourceKind.NONE
        }
    }

    private fun parseConfig(args: Any?): RecordingConfig? {
        val map = args as? Map<*, *> ?: return null
        val codecTag = map["codec"] as? String ?: "h264"
        val codec = VideoCodecKind.fromTag(codecTag) ?: return null
        val width = map["width"] as? Int ?: return null
        val height = map["height"] as? Int ?: return null
        val fps = map["fps"] as? Int ?: return null
        val videoBitrate = when (val raw = map["videoBitrateBps"]) {
            is Long -> raw
            is Int -> raw.toLong()
            else -> return null
        }
        val audioBitrate = when (val raw = map["audioBitrateBps"]) {
            is Long -> raw
            is Int -> raw.toLong()
            else -> return null
        }
        val micEnabled = map["micEnabled"] as? Boolean ?: return null
        val systemAudioEnabled = map["systemAudioEnabled"] as? Boolean ?: return null
        if (width <= 0 || height <= 0 || fps <= 0 || videoBitrate <= 0 || audioBitrate <= 0) return null
        return RecordingConfig(width, height, fps, videoBitrate, audioBitrate, codec, micEnabled, systemAudioEnabled)
    }

    private suspend fun sendCommand(action: String, result: MethodChannel.Result) {
        val intent = Intent(context, ScreenRecordService::class.java).setAction(action)
        runCatching {
            context.startService(intent)
        }
        result.success(true)
    }
}
