import 'dart:async';
import 'dart:math';
import 'dart:typed_data'; // App icons aur Audio ke liye
import 'dart:convert'; // Gemini JSON ke liye

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard aur Platform Channel ke liye

// NAYA: Orca ki audio play karne ke liye
import 'package:audioplayers/audioplayers.dart';

// HATA DIYA: flutter_tts
// import 'package:flutter_tts/flutter_tts.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:picovoice_flutter/picovoice_manager.dart';
import 'package:picovoice_flutter/picovoice_error.dart';

// NAYA: 'device_apps' ki jagah yeh package (BUILD FIX)
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';

import 'package:wakelock_plus/wakelock_plus.dart'; 
import 'package:http/http.dart' as http; 
import 'package:connectivity_plus/connectivity_plus.dart'; 
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:flutter_syntax_highlighter/flutter_syntax_highlighter.dart';
import 'package:clipboard/clipboard.dart';

// NAYA: Platform Channel se baat karne ke liye helper class
class OrcaTTS {
  static const platform = MethodChannel('com.jarvis.orca');
  final player = AudioPlayer();
  bool _isInitialized = false;

  Future<void> init(String accessKey) async {
    try {
      await platform.invokeMethod('initOrca', {'accessKey': accessKey});
      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
      rethrow; // Error ko aage bhej dein
    }
  }

  Future<void> speak(String text) async {
    if (!_isInitialized) throw Exception("Orca is not initialized.");
    
    // Player ko rokein (agar pehle se bol raha hai)
    await player.stop();

    // Native Java/Kotlin code se audio data (bytes) lein
    final Uint8List audioData = await platform.invokeMethod('speak', {'text': text});
    
    // Uss audio data ko play karein
    await player.play(BytesSource(audioData));
  }
  
  Future<void> stop() async {
    await player.stop();
  }

  Future<void> delete() async {
    await player.dispose();
    if(_isInitialized) {
      await platform.invokeMethod('deleteOrca');
      _isInitialized = false;
    }
  }
}


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

enum _AssistantState { idle, listening, thinking, speaking, error }

class ChatMessage {
  final String text;
  final bool isUser;
  final bool isCodeBlock; 
  ChatMessage(this.text, {this.isUser = false, this.isCodeBlock = false});
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Jarvis srs Launcher',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0F1E), 
        primaryColor: const Color(0xFF00BFFF), 
        colorScheme: ColorScheme.fromSwatch(
          brightness: Brightness.dark,
          primarySwatch: Colors.blue,
        ).copyWith(
          secondary: const Color(0xFF00BFFF),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161D30),
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
  // ***** API KEYS (Yahaan paste karein) *****
  final String _picovoiceAccessKey = "Du/wUGsdB9dU+um0teBOZNydHV2rzDiO6dbsGtLTqTGUYQF0RQzuIA==";
  final String _geminiApiKey = "AIzaSyBs-_4ek29Hu116CNJHjyH-DtkcmBx3xaU";
  // *****************************************

  PicovoiceManager? _picovoiceManager;
  
  // NAYA: Orca TTS (Native)
  late OrcaTTS _orcaTTS;

  _AssistantState _currentState = _AssistantState.idle;

  final List<ChatMessage> _chatHistory = [];
  final ScrollController _scrollController = ScrollController();
  
  // NAYA: Class ka naam Application -> AppInfo kar diya gaya hai
  List<AppInfo> _installedApps = [];
  bool _isOnline = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }
  
  Future<void> _initServices() async {
    WakelockPlus.enable(); 
    await _requestPermissions(); 
    
    var connectivityResult = await (Connectivity().checkConnectivity());
    _isOnline = connectivityResult.contains(ConnectivityResult.mobile) ||
                connectivityResult.contains(ConnectivityResult.wifi);
    
    Connectivity().onConnectivityChanged.listen((event) {
      setState(() {
         _isOnline = !(event.contains(ConnectivityResult.none));
      });
    });

    _initTts(); // NAYA: Orca (TTS) ko initialize karein
    _initPicovoice(); 
    _loadInstalledApps(); 
  }


  // NAYA: Function ko 'installed_apps' ke liye update kiya gaya
  void _loadInstalledApps() async {
     // 'device_apps' ki jagah 'installed_apps' ka istemal
     List<AppInfo> apps = await InstalledApps.getInstalledApps(
        true, // includeAppIcons
        true  // onlyAppsWithLaunchIntent
     );
     
     apps.sort((a, b) => a.name!.toLowerCase().compareTo(b.name!.toLowerCase()));
     setState(() {
       _installedApps = apps;
     });
  }

  void _initPicovoice() async {
    String keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    String contextPath = "assets/models/cheetah_params.pv"; 

    try {
      _picovoiceManager = await PicovoiceManager.create(
        _picovoiceAccessKey,
        keywordPath,
        _wakeWordCallback,
        contextPath,
        _inferenceCallback,
        // ***** ASLI FIX YAHAN HAI (Argument Error) *****
        // 6th argument (error) ko ek named parameter `processErrorCallback` hona chahiye
        processErrorCallback: (error) { 
        // *********************************************
          setState(() {
            _chatHistory.add(ChatMessage("Picovoice error: ${error.message}"));
            _currentState = _AssistantState.error;
          });
        },
      );

      _picovoiceManager?.start();
      setState(() {
         _chatHistory.add(ChatMessage("Say 'Hey Jarvis' or swipe up for apps..."));
      });

    } on PicovoiceException catch (err) {
      setState(() {
         _chatHistory.add(ChatMessage("Failed to init Picovoice: ${err.message}"));
         _currentState = _AssistantState.error;
      });
    }
  }
  
  // NAYA: Orca (TTS) ko initialize karein
  void _initTts() async {
    _orcaTTS = OrcaTTS();
    try {
      await _orcaTTS.init(_picovoiceAccessKey);
      
      // Audio player ko setup karein (Bolna kab poora hua)
      _orcaTTS.player.playbackEventStream.listen((event) { 
          if (event.processingState == ProcessingState.completed) {
            // Bolna poora ho gaya
            setState(() {
              _currentState = _AssistantState.idle;
            });
            _picovoiceManager?.start(); // Hotword waapas chalu karo
          }
      });
      
    } catch (e) {
       setState(() {
         _chatHistory.add(ChatMessage("Failed to init Orca TTS: $e"));
         _currentState = _AssistantState.error;
       });
    }
  }


  // "Hey Jarvis" sunne par
  void _wakeWordCallback() {
    if (_currentState == _AssistantState.idle) {
       setState(() {
        _currentState = _AssistantState.listening;
        _chatHistory.add(ChatMessage("Listening...", isUser: true));
        _scrollToBottom();
      });
    }
  }

  // Poora command sunne par
  void _inferenceCallback(Map<String, dynamic> inference) {
    String transcript = "I didn't understand that.";
    bool understood = false;

    if (inference.containsKey('isUnderstood') && inference['isUnderstood']) {
      transcript = inference['transcript'];
      understood = true;
    } else if (inference.containsKey('transcript') && inference['transcript'].isNotEmpty) {
       transcript = inference['transcript'];
       understood = true;
    }

    setState(() {
      _chatHistory.removeLast();
      _chatHistory.add(ChatMessage(transcript.isNotEmpty ? transcript : "...", isUser: true));
      _currentState = _AssistantState.thinking; 
      _scrollToBottom();
    });

    if (understood && transcript.isNotEmpty) {
      _processCommand(transcript);
    } else {
      _speak(transcript);
    }
  }
  
  // Command ko process karein (Offline ya Online)
  Future<void> _processCommand(String rawText) async {
      String command = rawText.toLowerCase();
      
      // OFFLINE: App kholne ke liye
      if (command.startsWith("open") || command.startsWith("launch")) {
         String appName = command.replaceFirst("open", "").replaceFirst("launch", "").trim();
         if (appName.isNotEmpty) {
           _openApp(appName);
         } else {
           _speak("Which app do you want to open?");
         }
         return;
      }
      
      // OFFLINE: Call karne ke liye
      else if (command.startsWith("call") || command.startsWith("phone")) {
         String contactName = command.replaceFirst("call", "").replaceFirst("phone", "").trim();
         if (contactName.isNotEmpty) {
           _makeCall(contactName);
         } else {
           _speak("Who do you want to call?");
         }
         return;
      }
      
      else if (command.contains("show all apps") || command.contains("open app drawer")) {
         _openAppDrawer();
         setState(() { _currentState = _AssistantState.idle; });
         return;
      }

      // ONLINE: Agar offline command nahi hai, toh Internet check karein
      if (_isOnline) {
        Map<String, String>? geminiResponse = await _getGeminiResponse(rawText);
        
        if (geminiResponse == null) {
          _speak("My AI brain connection has failed. I can only help with offline tasks for now, like opening apps or making calls.");
          return;
        }

        String spokenResponse = geminiResponse['spoken'] ?? "I found something, check your screen.";
        String displayData = geminiResponse['display'] ?? "";
        
        _speak(spokenResponse); 
        
        if(displayData.isNotEmpty) {
          setState(() {
             _chatHistory.add(ChatMessage(displayData, isCodeBlock: true));
             _scrollToBottom();
          });
        }
        
      } else {
        _speak("I'm offline. I can only help with offline tasks, like opening apps or making calls.");
      }
  }

  Future<void> _makeCall(String contactName) async {
    if (await Permission.contacts.isGranted && await Permission.phone.isGranted) {
      _speak("Searching for $contactName...");
      
      try {
        List<Contact> contacts = await FlutterContacts.getContacts(
          withProperties: true, withPhoto: false
        );
        Contact? targetContact;
        for (var contact in contacts) {
          if (contact.displayName.toLowerCase().contains(contactName)) {
            targetContact = contact;
            break;
          }
        }
        if (targetContact != null && targetContact.phones.isNotEmpty) {
            String number = targetContact.phones.first.number;
            _speak("Calling ${targetContact.displayName}...");
            await FlutterPhoneDirectCaller.callNumber(number);
            setState(() { _currentState = _AssistantState.idle; });
            _picovoiceManager?.start();
        } else {
          _speak("Sorry, I could not find $contactName in your contacts.");
        }
      } catch (e) {
        _speak("Sorry, I encountered an error trying to read your contacts.");
      }
    } else {
      _speak("I need contacts and phone permissions to make calls.");
      await _requestPermissions(); 
    }
  }

  Future<Map<String, String>?> _getGeminiResponse(String prompt) async {
    const String url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-09-2025:generateContent?key=";
    
    List<Map<String, dynamic>> historyPayload = _chatHistory
      .where((msg) => msg.text != "Listening...") 
      .map((msg) {
          return {
            "role": msg.isUser ? "user" : (msg.isCodeBlock ? "model" : "model"), 
            "parts": [{"text": msg.text}]
          };
      }).toList();
      
    if(historyPayload.isNotEmpty) {
       historyPayload.removeLast();
    }

    final body = jsonEncode({
      "contents": [
        ...historyPayload,
        {
          "role": "user",
          "parts": [{"text": prompt}]
        }
      ],
      "systemInstruction": {
        "parts": [{
          // ***** YAHI ASLI FIX HAI (Syntax Error) *****
          // Maine galti se do strings ko ek saath likh diya tha,
          // ab yeh ek hi multi-line string (''') hai.
          "text": """You are Jarvis srs, a helpful voice assistant in a launcher.
You MUST answer in two parts, separated by '|||'.
Part 1: A short, conversational response to be spoken aloud (DO NOT mention the code block).
Part 2: The code block or data to be displayed (if any).
If there is no code, Part 2 should be 'NONE'.
EXAMPLE 1: User asks 'write a python function to add numbers'.
Your response: Here is the Python function you asked for.|||```python
def add(a, b):
  return a + b