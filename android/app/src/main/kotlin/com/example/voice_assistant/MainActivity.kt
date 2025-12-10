package com.example.voice_assistant

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import ai.picovoice.orca.Orca
import ai.picovoice.orca.OrcaAudio
import ai.picovoice.orca.OrcaError
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.jarvis.orca"
    private var orca: Orca? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "initOrca") {
                val accessKey = call.argument<String>("accessKey")
                if (accessKey == null) {
                    result.error("INVALID_ARGUMENT", "AccessKey is missing", null)
                    return@setMethodCallHandler
                }

                try {
                    // FIX: Use Builder pattern instead of private constructor
                    orca = Orca.Builder()
                        .setAccessKey(accessKey)
                        .build(context)
                    result.success(null)
                } catch (e: OrcaError) {
                    result.error("INIT_ERROR", e.message, null)
                } catch (e: Exception) {
                    result.error("INIT_ERROR", e.message, null)
                }
            } 
            else if (call.method == "speak") {
                val text = call.argument<String>("text")
                if (text == null) {
                    result.error("INVALID_ARGUMENT", "Text is missing", null)
                    return@setMethodCallHandler
                }

                if (orca == null) {
                    result.error("UNINITIALIZED", "Orca is not initialized", null)
                    return@setMethodCallHandler
                }

                try {
                    // FIX: Handle OrcaAudio object instead of ShortArray directly
                    val audio: OrcaAudio = orca!!.synthesize(text)
                    val pcm: ShortArray = audio.pcm

                    // Convert ShortArray (16-bit) to ByteArray (Little Endian) for Flutter
                    val byteBuffer = ByteBuffer.allocate(pcm.size * 2)
                    byteBuffer.order(ByteOrder.LITTLE_ENDIAN)
                    for (s in pcm) {
                        byteBuffer.putShort(s)
                    }
                    
                    // Return raw PCM bytes. 
                    // Note: Depending on audio player on Flutter side, you might need a WAV header here.
                    // But raw bytes is standard for 'BytesSource' if configured correctly.
                    result.success(byteBuffer.array())
                } catch (e: OrcaError) {
                    result.error("SPEAK_ERROR", e.message, null)
                } catch (e: Exception) {
                    result.error("SPEAK_ERROR", e.message, null)
                }
            } 
            else if (call.method == "deleteOrca") {
                orca?.delete()
                orca = null
                result.success(null)
            } 
            else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        orca?.delete()
        super.onDestroy()
    }
}