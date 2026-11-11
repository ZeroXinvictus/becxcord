package com.bexxcord.app

import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class BubbleService : Service() {

    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var rootView: LinearLayout? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (rootView != null) return START_NOT_STICKY
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        val windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#151A26"))
                cornerRadius = 28f
            }
            setPadding(6, 6, 6, 6)
        }
        val toggleButton = Button(this).apply {
            text = getString(R.string.bubble_pause)
            setBackgroundColor(Color.TRANSPARENT)
            setTextColor(Color.parseColor("#F2F5FA"))
            textSize = 12f
            setOnClickListener {
                postCommand(ScreenRecordService.ACTION_PAUSE, ScreenRecordService.ACTION_RESUME)
            }
        }
        val stopButton = Button(this).apply {
            text = getString(R.string.bubble_stop)
            setBackgroundColor(Color.TRANSPARENT)
            setTextColor(Color.parseColor("#EF4444"))
            textSize = 12f
            setOnClickListener {
                postCommand(ScreenRecordService.ACTION_STOP, ScreenRecordService.ACTION_STOP)
            }
        }
        container.addView(
            toggleButton,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        container.addView(
            stopButton,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        val params = WindowManager.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            android.graphics.PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = 120
        }
        windowManager.addView(container, params)
        rootView = container
        scope.launch {
            RecorderBridge.state.collect { state ->
                toggleButton.text = if (state is RecorderState.Paused) {
                    getString(R.string.bubble_resume)
                } else {
                    getString(R.string.bubble_pause)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun postCommand(primary: String, fallback: String) {
        val state = RecorderBridge.state.value
        val action = when (state) {
            is RecorderState.Recording -> primary
            is RecorderState.Paused -> fallback
            else -> ScreenRecordService.ACTION_STOP
        }
        startService(Intent(this, ScreenRecordService::class.java).setAction(action))
    }

    override fun onDestroy() {
        rootView?.let { view ->
            runCatching {
                val windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
                windowManager.removeView(view)
            }
        }
        rootView = null
        scope.cancel()
        super.onDestroy()
    }
}
