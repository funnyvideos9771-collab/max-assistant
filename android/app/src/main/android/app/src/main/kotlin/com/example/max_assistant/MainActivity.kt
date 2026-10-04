package com.example.max_assistant

import android.content.Context
import android.media.AudioManager
import android.telecom.TelecomManager
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.max.assistant/telecom"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartEntrypoint.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "answerCallAndSpeaker") {
                val success = answerCallAndEnableSpeaker()
                result.success(success)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun answerCallAndEnableSpeaker(): Boolean {
        return try {
            val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                telecomManager.acceptRingingCall()
            }
            audioManager.mode = AudioManager.MODE_IN_CALL
            audioManager.isSpeakerphoneOn = true
            true
        } catch (e: Exception) {
            false
        }
    }
}
