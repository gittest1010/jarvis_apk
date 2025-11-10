// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:picovoice_flutter/picovoice_manager.dart';
import 'package:picovoice_flutter/picovoice_error.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:flutter_syntax_highlighter/flutter_syntax_highlighter.dart';
import 'package:clipboard/clipboard.dart';

/// ---------------- ORCA TTS HANDLER ----------------
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
      rethrow;
    }
  }

  Future<void> speak(String text) async {
    if (!_isInitialized) throw Exception("Orca is not initialized.");
    await player.stop();
    final Uint8List audioData =
        await platform.invokeMethod('speak', {'text': text});
    await player.play(BytesSource(audioData));
  }

  Future<void> stop() async => player.stop();

  Future<void> delete() async {
    await player.dispose();
    if (_isInitialized) {
      await platform.invokeMethod('deleteOrca');
      _isInitialized = false;
    }
  }
}

/// ---------------- APP ENTRY ----------------
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
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0F1E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00BFFF),
          secondary: Color(0xFF00BFFF),
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

/// ---------------- MAIN SCREEN ----------------
class VoiceAssistantScreen extends StatefulWidget {
  const VoiceAssistantScreen({super.key});
  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen> {
  final String _picovoiceAccessKey = "Du/wUGsdB9dU+um0teBOZNydHV2rzDiO6dbsGtLTqTGUYQF0RQzuIA==";
  final String _geminiApiKey = "AIzaSyBs-_4ek29Hu116CNJHjyH-DtkcmBx3xaU";

  PicovoiceManager? _picovoiceManager;
  late OrcaTTS _orcaTTS;
  _AssistantState _currentState = _AssistantState.idle;
  final List<ChatMessage> _chatHistory = [];
  final ScrollController _scrollController = ScrollController();
  List<AppInfo> _installedApps = [];
  bool _isOnline = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    await WakelockPlus.enable();
    await _requestPermissions();

    var connectivityResult = await Connectivity().checkConnectivity();
    _isOnline = connectivityResult == ConnectivityResult.mobile ||
        connectivityResult == ConnectivityResult.wifi;

    Connectivity().onConnectivityChanged.listen((event) {
      setState(() {
        _isOnline =
            event == ConnectivityResult.mobile || event == ConnectivityResult.wifi;
      });
    });

    await _initTts();
    await _initPicovoice();
    await _loadInstalledApps();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.contacts,
      Permission.phone,
      Permission.storage
    ].request();
  }

  Future<void> _loadInstalledApps() async {
    List<AppInfo> apps =
        await InstalledApps.getInstalledApps(true, true); // with icons
    apps.sort((a, b) => a.name!.toLowerCase().compareTo(b.name!.toLowerCase()));
    setState(() => _installedApps = apps);
  }

  Future<void> _initPicovoice() async {
    const keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    const contextPath = "assets/models/cheetah_params.pv";

    try {
      _picovoiceManager = await PicovoiceManager.create(
        _picovoiceAccessKey,
        keywordPath,
        _wakeWordCallback,
        contextPath,
        _inferenceCallback,
        processErrorCallback: (error) {
          setState(() {
            _chatHistory.add(ChatMessage("Picovoice error: ${error.message}"));
            _currentState = _AssistantState.error;
          });
        },
      );

      await _picovoiceManager?.start();
      setState(() {
        _chatHistory
            .add(ChatMessage("Say 'Hey Jarvis' or swipe up for apps..."));
      });
    } on PicovoiceException catch (err) {
      setState(() {
        _chatHistory
            .add(ChatMessage("Failed to init Picovoice: ${err.message}"));
        _currentState = _AssistantState.error;
      });
    }
  }

  Future<void> _initTts() async {
    _orcaTTS = OrcaTTS();
    try {
      await _orcaTTS.init(_picovoiceAccessKey);
      _orcaTTS.player.playbackEventStream.listen((event) {
        if (event.processingState == ProcessingState.completed) {
          setState(() => _currentState = _AssistantState.idle);
          _picovoiceManager?.start();
        }
      });
    } catch (e) {
      setState(() {
        _chatHistory.add(ChatMessage("Failed to init Orca TTS: $e"));
        _currentState = _AssistantState.error;
      });
    }
  }

  void _wakeWordCallback() {
    if (_currentState == _AssistantState.idle) {
      setState(() {
        _currentState = _AssistantState.listening;
        _chatHistory.add(ChatMessage("Listening...", isUser: true));
        _scrollToBottom();
      });
    }
  }

  void _inferenceCallback(Map<String, dynamic> inference) {
    String transcript = "I didn't understand that.";
    bool understood = false;

    if (inference['isUnderstood'] == true) {
      transcript = inference['transcript'];
      understood = true;
    } else if ((inference['transcript'] ?? '').isNotEmpty) {
      transcript = inference['transcript'];
      understood = true;
    }

    setState(() {
      if (_chatHistory.isNotEmpty) _chatHistory.removeLast();
      _chatHistory.add(ChatMessage(transcript, isUser: true));
      _currentState = _AssistantState.thinking;
      _scrollToBottom();
    });

    if (understood) {
      _processCommand(transcript);
    } else {
      _speak(transcript);
    }
  }

  Future<void> _processCommand(String rawText) async {
    String command = rawText.toLowerCase();

    if (command.startsWith("open") || command.startsWith("launch")) {
      String appName =
          command.replaceFirst("open", "").replaceFirst("launch", "").trim();
      if (appName.isNotEmpty) {
        _openApp(appName);
      } else {
        _speak("Which app do you want to open?");
      }
      return;
    }

    if (command.startsWith("call") || command.startsWith("phone")) {
      String name =
          command.replaceFirst("call", "").replaceFirst("phone", "").trim();
      if (name.isNotEmpty) {
        _makeCall(name);
      } else {
        _speak("Who do you want to call?");
      }
      return;
    }

    if (command.contains("show all apps") ||
        command.contains("open app drawer")) {
      _openAppDrawer();
      setState(() => _currentState = _AssistantState.idle);
      return;
    }

    if (_isOnline) {
      Map<String, String>? geminiResponse = await _getGeminiResponse(rawText);
      if (geminiResponse == null) {
        _speak(
            "My AI brain connection has failed. I can only help with offline tasks for now.");
        return;
      }
      String spoken = geminiResponse['spoken'] ?? "";
      String display = geminiResponse['display'] ?? "";
      _speak(spoken);
      if (display.isNotEmpty && display != "NONE") {
        setState(() {
          _chatHistory.add(ChatMessage(display, isCodeBlock: true));
          _scrollToBottom();
        });
      }
    } else {
      _speak(
          "I'm offline. I can only help with offline tasks like opening apps or making calls.");
    }
  }

  Future<void> _makeCall(String name) async {
    if (await Permission.contacts.isGranted &&
        await Permission.phone.isGranted) {
      _speak("Searching for $name...");
      try {
        List<Contact> contacts =
            await FlutterContacts.getContacts(withProperties: true);
        Contact? target = contacts.firstWhere(
          (c) => c.displayName.toLowerCase().contains(name),
          orElse: () => Contact(),
        );
        if (target.phones.isNotEmpty) {
          String number = target.phones.first.number;
          _speak("Calling ${target.displayName}...");
          await FlutterPhoneDirectCaller.callNumber(number);
          setState(() => _currentState = _AssistantState.idle);
          _picovoiceManager?.start();
        } else {
          _speak("Couldn't find $name in your contacts.");
        }
      } catch (e) {
        _speak("Sorry, I encountered an error while reading contacts.");
      }
    } else {
      _speak("I need contacts and phone permissions to make calls.");
      await _requestPermissions();
    }
  }

  Future<Map<String, String>?> _getGeminiResponse(String prompt) async {
    const String url =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-09-2025:generateContent?key=";

    List<Map<String, dynamic>> historyPayload = _chatHistory
        .where((m) => m.text != "Listening...")
        .map((m) => {
              "role": m.isUser ? "user" : "model",
              "parts": [
                {"text": m.text}
              ]
            })
        .toList();

    if (historyPayload.isNotEmpty) historyPayload.removeLast();

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
            "text": """You are Jarvis SRS, a helpful AI assistant inside a smart launcher.
Answer every query in two parts separated by '|||'.
Part 1: A short, conversational response for voice.
Part 2: The code block or data for display (or 'NONE').

Example 1:
User: write python code for add function.
Your response: Here is the Python function you asked for.|||```python
def add(a, b):
    return a + b
