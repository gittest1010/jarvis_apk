import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Voice Assistant',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          elevation: 0,
        ),
      ),
      home: const VoiceAssistantScreen(),
    );
  }
}

class VoiceAssistantScreen extends StatefulWidget {
  const VoiceAssistantScreen({super.key});

  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen> {
  // Speech-to-Text object
  late stt.SpeechToText _speech;
  // Text-to-Speech object
  late FlutterTts _flutterTts;

  bool _isListening = false;
  bool _isSpeaking = false;
  String _recognizedText = "Tap the mic and start speaking...";

  //confidence level
  double _confidence = 1.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  // Sabhi packages ko initialize karein
  void _init() async {
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();

    // Permissions check karein
    await _requestPermissions();

    // TTS state handlers set karein
    _flutterTts.setStartHandler(() {
      setState(() {
        _isSpeaking = true;
      });
    });

    _flutterTts.setCompletionHandler(() {
      setState(() {
        _isSpeaking = false;
      });
    });

    _flutterTts.setErrorHandler((msg) {
      setState(() {
        _isSpeaking = false;
        _recognizedText = "Error speaking: $msg";
      });
    });

    // Speech-to-Text ko initialize karein
    bool available = await _speech.initialize(
      onStatus: (val) => print('onStatus: $val'),
      onError: (val) => print('onError: $val'),
    );
    if (!available) {
      setState(() {
        _recognizedText = "Speech recognition not available.";
      });
    }
  }

  // Permissions request karein
  Future<void> _requestPermissions() async {
    // Microphone permission
    if (await Permission.microphone.isDenied) {
      await Permission.microphone.request();
    }
    // Speech recognition permission (Android 12+ ke liye)
    if (await Permission.speech.isDenied) {
      await Permission.speech.request();
    }
  }

  @override
  void dispose() {
    // Resources ko free karein
    _speech.stop();
    _flutterTts.stop();
    super.dispose();
  }

  // UI (Screen)
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Voice Assistant'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Yahaan recognized text dikhega
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(20.0),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F1F),
                  borderRadius: BorderRadius.circular(12.0),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Center(
                  child: SingleChildScrollView(
                    child: Text(
                      _recognizedText,
                      style: const TextStyle(
                        fontSize: 24.0,
                        fontWeight: FontWeight.w300,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Status message
            if (_isListening)
              const Text(
                "Listening...",
                style: TextStyle(color: Colors.blueAccent, fontSize: 16),
              ),
            if (_isSpeaking)
              const Text(
                "Speaking...",
                style: TextStyle(color: Colors.greenAccent, fontSize: 16),
              ),

            const SizedBox(height: 20),
          ],
        ),
      ),
      // Main microphone button
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: TweenAnimationBuilder<double>(
        // Ye animation button ko pulse (chhota-bada) karega jab listening ho
        tween: Tween(begin: 1.0, end: _isListening ? 1.2 : 1.0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        builder: (context, scale, child) {
          return Transform.scale(
            scale: scale,
            child: FloatingActionButton(
              onPressed: _toggleListening,
              backgroundColor: _isListening ? Colors.redAccent : Colors.blueAccent,
              shape: const CircleBorder(),
              child: Icon(
                _isListening
                    ? Icons.mic
                    : Icons.mic_none,
                color: Colors.white,
                size: 30,
              ),
            ),
          );
        },
      ),
    );
  }

  // Button dabane par ye function chalega
  void _toggleListening() {
    if (_isSpeaking) {
      // Agar bol raha hai, to use rokein
      _flutterTts.stop();
      setState(() => _isSpeaking = false);
    } else if (_isListening) {
      // Agar sun raha hai, to use rokein
      _stopListening();
    } else {
      // Agar kuch nahi kar raha, to sunna shuru karein
      _startListening();
    }
  }

  // Sunna shuru karein
  void _startListening() async {
    bool available = await _speech.initialize();
    if (!available) {
      setState(() {
        _recognizedText = "Speech recognition is not available.";
      });
      return;
    }

    setState(() {
      _isListening = true;
      _recognizedText = "Listening...";
      _confidence = 1.0;
    });

    _speech.listen(
      onResult: (val) {
        setState(() {
          _recognizedText = val.recognizedWords;
          if (val.hasConfidenceRating && val.confidence > 0) {
            _confidence = val.confidence;
          }
        });

        // Jaise hi bolna band karega, final result milne par...
        if (val.finalResult) {
          setState(() {
            _isListening = false;
          });
          // ...jo suna, use waapas bolo
          if (_recognizedText.isNotEmpty) {
            _speak(_recognizedText);
          }
        }
      },
      listenFor: const Duration(seconds: 30), // Max 30 sec tak sunega
      pauseFor: const Duration(seconds: 5), // 5 sec chup rehne par band
    );
  }

  // Sunna band karein
  void _stopListening() {
    _speech.stop();
    setState(() {
      _isListening = false;
    });
  }

  // Text ko bol kar sunayein
  Future<void> _speak(String text) async {
    if (text.isNotEmpty) {
      setState(() => _isSpeaking = true);
      await _flutterTts.setLanguage("en-US"); // Aap bhasha badal sakte hain
      await _flutterTts.setPitch(1.0); // Awaaz ka pitch
      await _flutterTts.setSpeechRate(0.5); // Bolne ki speed
      await _flutterTts.speak(text);
    }
  }
}
