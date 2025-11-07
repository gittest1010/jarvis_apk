import 'dart:async';
import 'dart:math';
import 'dart:typed_data'; // App icons ke liye zaroori
import 'dart:convert'; // Gemini JSON ke liye zaroori

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard ke liye
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

// NAYE IMPORTS
import 'package:picovoice_flutter/picovoice_manager.dart';
import 'package:picovoice_flutter/picovoice_error.dart';
import 'package:device_apps/device_apps.dart'; 
import 'package:wakelock_plus/wakelock_plus.dart'; 
import 'package:http/http.dart' as http; 
import 'package:connectivity_plus/connectivity_plus.dart'; 
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';

// NAYE PACKAGES (CODE DIKHAANE KE LIYE)
import 'package:flutter_syntax_highlighter/flutter_syntax_highlighter.dart';
import 'package:clipboard/clipboard.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

// Assistant ki state track karne ke liye
enum _AssistantState { idle, listening, thinking, speaking, error }

// Chat message ka structure
class ChatMessage {
  final String text;
  final bool isUser;
  final bool isCodeBlock; // Code block ke liye
  ChatMessage(this.text, {this.isUser = false, this.isCodeBlock = false});
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Jarvis srs Launcher', // NAAM UPDATE KIYA GAYA
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0F1E), // Dark Navy Blue
        primaryColor: const Color(0xFF00BFFF), // Deep Sky Blue (Accent)
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
  late FlutterTts _flutterTts;

  _AssistantState _currentState = _AssistantState.idle;

  // Chat History (Memory)
  final List<ChatMessage> _chatHistory = [];
  final ScrollController _scrollController = ScrollController();
  
  // App List (Optimization)
  List<Application> _installedApps = [];
  bool _isOnline = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }
  
  Future<void> _initServices() async {
    // Screen ko jagaaye rakhein (Launcher ke liye zaroori)
    WakelockPlus.enable(); 
    // Permissions maangein
    await _requestPermissions(); 
    
    // Internet check karein
    var connectivityResult = await (Connectivity().checkConnectivity());
    _isOnline = connectivityResult.contains(ConnectivityResult.mobile) ||
                connectivityResult.contains(ConnectivityResult.wifi);
    
    // Internet changes ko sunte rahein
    Connectivity().onConnectivityChanged.listen((event) {
      setState(() {
         _isOnline = !(event.contains(ConnectivityResult.none));
      });
    });

    _initTts();
    _initPicovoice();
    _loadInstalledApps(); // App list ko background mein load karein
  }

  // App list ko ek baar load karke save karein
  void _loadInstalledApps() async {
     List<Application> apps = await DeviceApps.getInstalledApplications(
        includeAppIcons: true,
        onlyAppsWithLaunchIntent: true,
        includeSystemApps: false 
     );
     apps.sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
     setState(() {
       _installedApps = apps;
     });
  }

  // Picovoice (Hotword + STT) ko initialize karein
  void _initPicovoice() async {
    // Apni files ke naam check kar lein
    String keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    String contextPath = "assets/models/cheetah_params.pv"; 

    try {
      _picovoiceManager = await PicovoiceManager.create(
        _picovoiceAccessKey,
        keywordPath,
        _wakeWordCallback, // Hotword ("Hey Jarvis")
        contextPath,
        _inferenceCallback, // STT (Command)
        (error) { // Error handler
          setState(() {
            _chatHistory.add(ChatMessage("Picovoice error: ${error.message}"));
            _currentState = _AssistantState.error;
          });
        },
      );

      _picovoiceManager?.start(); // Sunna shuru karein
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

  // "Hey Jarvis" sunne par yeh function chalega
  void _wakeWordCallback() {
    if (_currentState == _AssistantState.idle) {
       setState(() {
        _currentState = _AssistantState.listening;
        _chatHistory.add(ChatMessage("Listening...", isUser: true));
        _scrollToBottom();
      });
    }
  }

  // Poora command sunne par yeh function chalega
  void _inferenceCallback(Map<String, dynamic> inference) {
    String transcript = "I didn't understand that.";
    bool understood = false;

    // Check karein ki Picovoice ne command samjha ya nahi
    if (inference.containsKey('isUnderstood') && inference['isUnderstood']) {
      transcript = inference['transcript'];
      understood = true;
    } else if (inference.containsKey('transcript') && inference['transcript'].isNotEmpty) {
       transcript = inference['transcript'];
       understood = true;
    }

    setState(() {
      _chatHistory.removeLast(); // "Listening..." ko hataayein
      _chatHistory.add(ChatMessage(transcript.isNotEmpty ? transcript : "...", isUser: true)); // User ka command daalein
      _currentState = _AssistantState.thinking; // Sochne waala state
      _scrollToBottom();
    });

    if (understood && transcript.isNotEmpty) {
      _processCommand(transcript); // Command ko process karein
    } else {
      _speak(transcript); // Error ko bol kar sunayein
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
         return; // Command poora hua
      }
      
      // OFFLINE: Call karne ke liye
      else if (command.startsWith("call") || command.startsWith("phone")) {
         String contactName = command.replaceFirst("call", "").replaceFirst("phone", "").trim();
         if (contactName.isNotEmpty) {
           _makeCall(contactName);
         } else {
           _speak("Who do you want to call?");
         }
         return; // Command poora hua
      }
      
      // OFFLINE: App drawer kholne ke liye
      else if (command.contains("show all apps") || command.contains("open app drawer")) {
         _openAppDrawer();
         setState(() { _currentState = _AssistantState.idle; });
         return; // Command poora hua
      }

      // ONLINE: Agar offline command nahi hai, toh Internet check karein
      if (_isOnline) {
        // Gemini se 2-part response lein
        Map<String, String> geminiResponse = await _getGeminiResponse(rawText);
        
        String spokenResponse = geminiResponse['spoken'] ?? "I found something, check your screen.";
        String displayData = geminiResponse['display'] ?? "";
        
        // Jawaab ko bolo
        _speak(spokenResponse); 
        
        // Agar code hai, toh usse alag se add karo
        if(displayData.isNotEmpty) {
          setState(() {
             _chatHistory.add(ChatMessage(displayData, isCodeBlock: true));
             _scrollToBottom();
          });
        }
        
      } else {
        // OFFLINE: User ko bataayein ki internet nahi hai
        _speak("I can't answer that without an internet connection. I can only open apps or make calls when offline.");
      }
  }

  // Phone call karne ka function
  Future<void> _makeCall(String contactName) async {
    // Permission check karein
    if (await Permission.contacts.isGranted && await Permission.phone.isGranted) {
      _speak("Searching for $contactName...");
      
      try {
        // Contacts dhoondhein
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
            
            // Call karne ke baad, state ko idle par set karein
            setState(() { _currentState = _AssistantState.idle; });
            _picovoiceManager?.start();

        } else {
          _speak("Sorry, I could not find $contactName in your contacts.");
        }
      } catch (e) {
        _speak("Sorry, I encountered an error trying to read your contacts.");
      }
    } else {
      // Agar permission nahi di
      _speak("I need contacts and phone permissions to make calls.");
      await _requestPermissions(); // Dobara poochein
    }
  }

  // Gemini AI Brain (Memory + Code Generation ke saath)
  Future<Map<String, String>> _getGeminiResponse(String prompt) async {
    const String url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-09-2025:generateContent?key=";
    
    // Chat history ko Gemini format mein convert karein
    List<Map<String, dynamic>> historyPayload = _chatHistory
      .where((msg) => msg.text != "Listening...") // "Listening..." ko history mein na bhejjein
      .map((msg) {
          return {
            "role": msg.isUser ? "user" : (msg.isCodeBlock ? "model" : "model"), 
            "parts": [{"text": msg.text}]
          };
      }).toList();
      
    if(historyPayload.isNotEmpty) {
       historyPayload.removeLast(); // Aakhiri user prompt hataayein
    }

    final body = jsonEncode({
      "contents": [
        ...historyPayload, // Puraani history
        {
          "role": "user",
          "parts": [{"text": prompt}] // Naya prompt
        }
      ],
      // System Instruction (Jarvis srs ki personality)
      "systemInstruction": {
        "parts": [{
          "text": "You are Jarvis srs, a helpful voice assistant in a launcher. "
                  "You MUST answer in two parts, separated by '|||'. "
                  "Part 1: A short, conversational response to be spoken aloud (DO NOT mention the code block). "
                  "Part 2: The code block or data to be displayed (if any). "
                  "If there is no code, Part 2 should be 'NONE'. "
                  "EXAMPLE 1: User asks 'write a python function to add numbers'. "
                  "Your response: Here is the Python function you asked for.|||