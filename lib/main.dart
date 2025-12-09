import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';

// REPLACED PicovoiceManager with individual engines
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:cheetah_flutter/cheetah_manager.dart';
import 'package:cheetah_flutter/cheetah_error.dart';

import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';

import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:clipboard/clipboard.dart';

/// ORCA TTS via Platform Channel (native side required)
class OrcaTTS {
  static const platform = MethodChannel('com.jarvis.orca');
  final player = AudioPlayer();
  bool _isInitialized = false;

  Future<void> init(String accessKey) async {
    try {
      // Must match Kotlin side
      await platform.invokeMethod('initOrca', {'accessKey': accessKey});
      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
      print("Orca Init Error: $e");
      // Don't rethrow, just let it fail gracefully
    }
  }

  Future<void> speak(String text) async {
    if (!_isInitialized) {
      print("Orca ignored speak request (not initialized)");
      return;
    }
    await player.stop();
    try {
      final Uint8List audioData =
          await platform.invokeMethod('speak', {'text': text});
      await player.play(BytesSource(audioData));
    } catch (e) {
      print("Orca speak error: $e");
    }
  }

  Future<void> stop() async {
    await player.stop();
  }

  Future<void> delete() async {
    await player.dispose();
    if (_isInitialized) {
      try {
        await platform.invokeMethod('deleteOrca');
      } catch (_) {}
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
      title: 'Jarvis SRS Launcher',
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
  // ===== API KEYS =====
  // TODO: Replace with real keys or handle missing keys
  final String _picovoiceAccessKey = "YOUR_PICOVOICE_ACCESS_KEY_HERE";
  final String _geminiApiKey = "YOUR_GEMINI_API_KEY_HERE";
  // ====================

  PorcupineManager? _porcupineManager;
  CheetahManager? _cheetahManager;
  late OrcaTTS _orcaTTS;

  _AssistantState _currentState = _AssistantState.idle;

  final List<ChatMessage> _chatHistory = [];
  final ScrollController _scrollController = ScrollController();

  List<AppInfo> _installedApps = [];
  bool _isOnline = false;
  String _currentTranscript = "";

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _porcupineManager?.delete();
    _cheetahManager?.delete();
    _orcaTTS.delete();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _initServices() async {
    WakelockPlus.enable();
    await _requestPermissions();

    _checkConnectivity();
    Connectivity().onConnectivityChanged.listen((dynamic event) {
      _checkConnectivity();
    });

    await _initTts();
    await _loadInstalledApps();
    
    // Defer voice init slightly to ensure permissions are ready
    if (await Permission.microphone.isGranted) {
      _initVoiceEngines();
    }
  }

  Future<void> _checkConnectivity() async {
     final dynamic initial = await Connectivity().checkConnectivity();
    bool online;
    if (initial is List<ConnectivityResult>) {
      online = initial.any((r) =>
          r == ConnectivityResult.mobile || r == ConnectivityResult.wifi);
    } else {
      online = initial == ConnectivityResult.mobile ||
          initial == ConnectivityResult.wifi;
    }
    if(mounted) setState(() => _isOnline = online);
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.contacts,
      Permission.phone,
    ].request();
  }

  Future<void> _initTts() async {
    _orcaTTS = OrcaTTS();
    await _orcaTTS.init(_picovoiceAccessKey);

    // Resume listening after speaking
    _orcaTTS.player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() => _currentState = _AssistantState.idle);
      _startWakeHost();
    });
  }

  Future<void> _initVoiceEngines() async {
    String keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    String modelPath = "assets/models/cheetah_params.pv"; // STT model

    try {
      // 1. Initialize Porcupine (Wake Word)
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        _picovoiceAccessKey,
        [keywordPath],
        _wakeWordCallback,
      );

      // 2. Initialize Cheetah (STT)
      _cheetahManager = await CheetahManager.create(
        _picovoiceAccessKey,
        _sttCallback,
        _sttErrorCallback,
        modelPath: modelPath,
      );

      // Start listening for wake word initially
      await _startWakeHost();

      setState(() {
        _chatHistory.add(
            ChatMessage("Say 'Hey Jarvis' or tap apps..."));
      });
    } on PorcupineException catch (err) {
      _showError("Porcupine Init Error: ${err.message}");
    } on CheetahException catch (err) {
      _showError("Cheetah Init Error: ${err.message}");
    } catch (e) {
      _showError("Voice Init Error: $e");
    }
  }

  Future<void> _startWakeHost() async {
    if (_currentState == _AssistantState.listening || _currentState == _AssistantState.thinking) return;
    
    try {
      await _cheetahManager?.stopRecorder(); // Ensure STT is off
      await _porcupineManager?.start();
    } catch (e) {
      print("Error starting wake word: $e");
    }
  }

  Future<void> _stopWakeHost() async {
     try {
      await _porcupineManager?.stop();
    } catch (e) {
      print("Error stopping wake word: $e");
    }
  }

  void _wakeWordCallback(int keywordIndex) async {
    // Wake word detected!
    await _stopWakeHost();
    
    setState(() {
      _currentState = _AssistantState.listening;
      _currentTranscript = "";
      _chatHistory.add(ChatMessage("Listening...", isUser: true));
    });
    _scrollToBottom();
    
    // Start STT
    try {
      await _cheetahManager?.startRecorder();
    } catch (e) {
      _showError("Failed to start listening: $e");
      _currentState = _AssistantState.idle;
      _startWakeHost();
    }
  }

  void _sttCallback(String partialTranscript, bool isEndpoint) {
    if (_currentState != _AssistantState.listening) return;

    if (partialTranscript.isNotEmpty) {
      _currentTranscript += partialTranscript;
    }

    if (isEndpoint) {
      // Automatic silence detection end
      _stopListeningAndProcess();
    }
  }

  void _sttErrorCallback(CheetahException error) {
    _showError("STT Error: ${error.message}");
    _stopListeningAndProcess(); // Try to process whatever we have
  }

  Future<void> _stopListeningAndProcess() async {
    await _cheetahManager?.stopRecorder();
    
    setState(() {
      _currentState = _AssistantState.thinking;
       // Replace "Listening..." with actual text
      if (_chatHistory.isNotEmpty && _chatHistory.last.text == "Listening...") {
        _chatHistory.removeLast();
      }
      _chatHistory.add(ChatMessage(_currentTranscript.trim().isNotEmpty ? _currentTranscript : "...", isUser: true));
    });
    
    if (_currentTranscript.trim().isNotEmpty) {
      await _processCommand(_currentTranscript);
    } else {
      _currentState = _AssistantState.idle;
      await _startWakeHost();
    }
    _currentTranscript = "";
  }

  void _showError(String msg) {
    setState(() {
      _chatHistory.add(ChatMessage("Error: $msg"));
      _currentState = _AssistantState.error;
    });
  }

  Future<void> _loadInstalledApps() async {
    try {
      List<AppInfo> apps =
          await InstalledApps.getInstalledApps(true, true);
      apps.sort((a, b) => (a.name ?? a.packageName ?? '')
          .toLowerCase()
          .compareTo((b.name ?? b.packageName ?? '').toLowerCase()));
      setState(() {
        _installedApps = apps;
      });
    } catch (e) {
      print("Apps load error: $e");
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _speak(String text) {
    if (text.isEmpty) return;
    setState(() => _currentState = _AssistantState.speaking);
    _orcaTTS.speak(text);
  }

  // FORCE STOP / MANUAL TAP
  void _onMicTap() {
    if (_currentState == _AssistantState.listening) {
       _stopListeningAndProcess();
    } else if (_currentState == _AssistantState.idle) {
       // Manual trigger
       _wakeWordCallback(0);
    }
  }

  // ================= LOGIC AND COMMANDS =================

  Future<void> _processCommand(String rawText) async {
    String command = rawText.toLowerCase().trim();

    // OPEN APP
    if (command.startsWith("open") || command.startsWith("launch")) {
      String appName = command
          .replaceFirst("open", "")
          .replaceFirst("launch", "")
          .trim();
      if (appName.isNotEmpty) {
        _openApp(appName);
      } else {
        _speak("Which app?");
      }
      return;
    }

    // CALL CONTACT
    if (command.startsWith("call") || command.startsWith("phone")) {
      String contactName = command
          .replaceFirst("call", "")
          .replaceFirst("phone", "")
          .trim();
      if (contactName.isNotEmpty) {
        _makeCall(contactName);
      } else {
        _speak("Who do you want to call?");
      }
      return;
    }

    // SHOW APPS
    if (command.contains("show all apps") ||
        command.contains("open app drawer")) {
      _openAppDrawer();
      setState(() => _currentState = _AssistantState.idle);
      // We manually stopped listening, so restart wake word manually if needed, 
      // but usually openAppDrawer stays open.
       _startWakeHost();
      return;
    }

    // ONLINE AI (Gemini)
    if (_isOnline) {
      Map<String, String>? geminiResponse = await _getGeminiResponse(rawText);

      if (geminiResponse == null) {
        _speak(
            "I'm having trouble connecting to my brain.");
             setState(() => _currentState = _AssistantState.idle);
             _startWakeHost();
        return;
      }

      String spokenResponse =
          geminiResponse['spoken'] ?? "Here is what I found.";
      String displayData = geminiResponse['display'] ?? "";

      setState(() {
        _chatHistory.add(ChatMessage(spokenResponse));
      });
      _speak(spokenResponse);

      if (displayData.isNotEmpty) {
        setState(() {
          _chatHistory.add(ChatMessage(displayData, isCodeBlock: true));
        });
      }
      _scrollToBottom();
    } else {
      _speak(
          "I'm offline. I can open apps or make calls.");
           setState(() => _currentState = _AssistantState.idle);
           _startWakeHost();
    }
  }
  
  void _openApp(String appName) {
    // Simple fuzzy match
    try {
      final app = _installedApps.firstWhere(
        (a) => (a.name ?? "").toLowerCase().contains(appName.toLowerCase()),
      );
      InstalledApps.startApp(app.packageName!);
      _speak("Opening ${app.name}...");
      // App opens, we go background.
      setState(() => _currentState = _AssistantState.idle);
      _startWakeHost();
    } catch (e) {
      _speak("I couldn't find an app named $appName.");
       setState(() => _currentState = _AssistantState.idle);
       _startWakeHost();
    }
  }
  
  void _openAppDrawer() {
     // Just show list in UI? Or use native intent?
     // We have a list at the bottom of the screen usually...
     // Implementation depends on UI. For now, just speak.
     _speak("Opening app list...");
  }

  Future<void> _makeCall(String contactName) async {
    if (await Permission.contacts.isGranted &&
        await Permission.phone.isGranted) {
      _speak("Searching for $contactName...");

      try {
        List<Contact> contacts = await FlutterContacts.getContacts(
            withProperties: true, withPhoto: false);
        Contact? targetContact;
        final query = contactName.toLowerCase().trim();
        for (var contact in contacts) {
          if (contact.displayName.toLowerCase().contains(query)) {
            targetContact = contact;
            break;
          }
        }
        if (targetContact != null && targetContact.phones.isNotEmpty) {
          String number = targetContact.phones.first.number;
          _speak("Calling ${targetContact.displayName}...");
          await FlutterPhoneDirectCaller.callNumber(number);
          setState(() => _currentState = _AssistantState.idle);
          _startWakeHost();
        } else {
          _speak("Sorry, check your contacts.");
           setState(() => _currentState = _AssistantState.idle);
           _startWakeHost();
        }
      } catch (e) {
        _speak("Error accessing contacts.");
         setState(() => _currentState = _AssistantState.idle);
         _startWakeHost();
      }
    } else {
      _speak("I need permissions first.");
      await _requestPermissions();
       setState(() => _currentState = _AssistantState.idle);
       _startWakeHost();
    }
  }

  Future<Map<String, String>?> _getGeminiResponse(String prompt) async {
    const String baseUrl =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-09-2025:generateContent?key=";

    // Build minimal history (excluding "Listening...")
    List<Map<String, dynamic>> historyPayload = _chatHistory
        .where((msg) => msg.text != "Listening..." && !msg.text.startsWith("Say 'Hey"))
        .map((msg) {
      return {
        "role": msg.isUser ? "user" : "model",
        "parts": [
          {"text": msg.text}
        ]
      };
    }).toList();
    
    // Safety crop
    if (historyPayload.length > 10) {
        historyPayload = historyPayload.sublist(historyPayload.length - 10);
    }

    if (historyPayload.isNotEmpty && historyPayload.last["role"] == "user") {
      historyPayload.removeLast();
    }

    final body = jsonEncode({
      "contents": [
        ...historyPayload,
        {
          "role": "user",
          "parts": [
            {"text": prompt}
          ]
        }
      ],
      "systemInstruction": {
        "parts": [
          {
            "text":
                '''You are Jarvis SRS. Respond in exactly two parts separated by "|||":
- Part 1: Spoken reply. No markdown.
- Part 2: Screen display. Markdown/Code allowed. 'NONE' if empty.
''' 
          }
        ]
      }
    });

    try {
      final response = await http.post(
          Uri.parse(baseUrl + _geminiApiKey),
          headers: {'Content-Type': 'application/json'},
          body: body);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String fullText =
            data['candidates'][0]['content']['parts'][0]['text'] ?? "";
        
        final parts = fullText.split("|||");
        String spoken = parts[0].trim();
        String display = parts.length > 1 ? parts[1].trim() : "";
        if (display == "NONE") display = "";

        return {'spoken': spoken, 'display': display};
      } else {
          print("Gemini Error: ${response.body}");
      }
    } catch (e) {
      print("Gemini Net Error: $e");
    }
    return null;
  }
}