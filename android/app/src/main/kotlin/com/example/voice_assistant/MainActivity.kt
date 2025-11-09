package com.example.voice_assistant // IMPORTANT: Yahaan apna package naam zaroor check kar lein

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Orca ke imports
import ai.picovoice.orca.Orca
import ai.picovoice.orca.OrcaException
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.jarvis.orca" // Aapke code waala channel naam
    private var orca: Orca? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "initOrca" -> {
                            try {
                                val accessKey = call.argument<String>("accessKey")
                                
                                // NAYA: Asset se file padhne ka Kotlin tareeka
                                // FIX: Yahaan aapka file naam daal diya gaya hai
                                val modelPath = "orca_params_en_male.pv" 
                                // (Zaroor check karein ki file ka naam 'android/app/src/main/assets/' mein yahi hai)
                                
                                // File ko cache directory mein copy karein taaki Orca usse read kar sake
                                val modelFile = java.io.File(cacheDir, modelPath)
                                if (!modelFile.exists()) {
                                    val assetStream = assets.open(modelPath)
                                    val fileOutStream = java.io.FileOutputStream(modelFile)
                                    assetStream.copyTo(fileOutStream)
                                    assetStream.close()
                                    fileOutStream.close()
                                }

                                orca = Orca(accessKey, modelFile.absolutePath)
                                
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("INIT_ERROR", e.message, null)
                            }
                        }

                        "speak" -> {
                            try {
                                val text = call.argument<String>("text")
                                // Orca int16[] return karta hai, usse byte[] mein badlein
                                val pcm: ShortArray = orca!!.synthesize(text)
                                val buffer = ByteBuffer.allocate(pcm.size * 2) // 16-bit = 2 bytes
                                buffer.order(ByteOrder.LITTLE_ENDIAN)
                                for (shortVal in pcm) {
                                    buffer.putShort(shortVal)
                                }
                                
                                result.success(buffer.array())
                            } catch (e: OrcaException) {
                                result.error("SYNTH_ERROR", e.message, null)
                            }
                        }

                        "deleteOrca" -> {
                             orca?.delete()
                             orca = null
                             result.success(true)
                        }

                        else -> {
                            result.notImplemented()
                        }
                    }
                }
    }
}