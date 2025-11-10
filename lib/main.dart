import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
import 'package:clipboard/clipboard.dart';

/// ORCA TTS via Platform Channel (native side required)
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

  Future<void> stop() async {
    await player.stop();
  }

  Future<void> delete() async {
    await player.dispose();
    if (_isInitialized) {
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
  final String _picovoiceAccessKey = "YOUR_PICOVOICE_ACCESS_KEY_HERE";
  final String _geminiApiKey = "YOUR_GEMINI_API_KEY_HERE";
  // ====================

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

  @override
  void dispose() {
    _scrollController.dispose();
    _picovoiceManager?.stop();
    _orcaTTS.delete();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _initServices() async {
    WakelockPlus.enable();
    await _requestPermissions();

    // Connectivity (handle old/new versions defensively)
    final dynamic initial = await Connectivity().checkConnectivity();
    bool online;
    if (initial is List<ConnectivityResult>) {
      online = initial.any((r) =>
          r == ConnectivityResult.mobile || r == ConnectivityResult.wifi);
    } else {
      online = initial == ConnectivityResult.mobile ||
          initial == ConnectivityResult.wifi;
    }
    setState(() => _isOnline = online);

    Connectivity().onConnectivityChanged.listen((dynamic event) {
      bool nowOnline;
      if (event is List<ConnectivityResult>) {
        nowOnline = event.any((r) => r != ConnectivityResult.none);
      } else {
        nowOnline = event != ConnectivityResult.none;
      }
      if (mounted) setState(() => _isOnline = nowOnline);
    });

    await _initTts();
    _initPicovoice();
    _loadInstalledApps();
  }

  Future<void> _initTts() async {
    _orcaTTS = OrcaTTS();
    try {
      await _orcaTTS.init(_picovoiceAccessKey);

      // audioplayers correct completion stream
      _orcaTTS.player.onPlayerComplete.listen((_) {
        if (!mounted) return;
        setState(() => _currentState = _AssistantState.idle);
        _picovoiceManager?.start();
      });
    } catch (e) {
      setState(() {
        _chatHistory.add(ChatMessage("Failed to init Orca TTS: $e"));
        _currentState = _AssistantState.error;
      });
    }
  }

  void _initPicovoice() async {
    // Ensure these asset files exist and are declared in pubspec.yaml
    String keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    String contextPath = "assets/models/cheetah_params.pv";

    try {
      _picovoiceManager = await PicovoiceManager.create(
        _picovoiceAccessKey,
        keywordPath,
        _wakeWordCallback,
        contextPath,
        _inferenceCallback,
        // If your package version supports an error callback:
        // errorCallback: (error) { ... }
        // or processErrorCallback: (error) { ... }
      );

      await _picovoiceManager?.start();
      setState(() {
        _chatHistory.add(
            ChatMessage("Say 'Hey Jarvis' or tap the apps button below..."));
      });
    } on PicovoiceException catch (err) {
      setState(() {
        _chatHistory.add(ChatMessage("Failed to init Picovoice: ${err.message}"));
        _currentState = _AssistantState.error;
      });
    } catch (e) {
      setState(() {
        _chatHistory.add(ChatMessage("Picovoice init error: $e"));
        _currentState = _AssistantState.error;
      });
    }
  }

  void _loadInstalledApps() async {
    try {
      List<AppInfo> apps =
          await InstalledApps.getInstalledApps(true, true); // icons + launchable
      apps.sort((a, b) => (a.name ?? a.packageName ?? '')
          .toLowerCase()
          .compareTo((b.name ?? b.packageName ?? '').toLowerCase()));
      setState(() {
        _installedApps = apps;
      });
    } catch (e) {
      setState(() {
        _chatHistory.add(ChatMessage("Failed to load apps: $e"));
      });
    }
  }

  void _wakeWordCallback() {
    if (_currentState == _AssistantState.idle) {
      setState(() {
        _currentState = _AssistantState.listening;
        _chatHistory.add(ChatMessage("Listening...", isUser: true));
      });
      _scrollToBottom();
    }
  }

  void _inferenceCallback(Map<String, dynamic> inference) {
    String transcript = "I didn't understand that.";
    bool understood = false;

    if (inference.containsKey('isUnderstood') && inference['isUnderstood']) {
      transcript = inference['transcript'];
      understood = true;
    } else if (inference.containsKey('transcript') &&
        (inference['transcript']?.toString().isNotEmpty ?? false)) {
      transcript = inference['transcript'];
      understood = true;
    }

    setState(() {
      if (_chatHistory.isNotEmpty &&
          _chatHistory.last.text == "Listening..." &&
          _chatHistory.last.isUser) {
        _chatHistory.removeLast();
      }
      _chatHistory.add(ChatMessage(
          transcript.isNotEmpty ? transcript : "...",
          isUser: true));
      _currentState = _AssistantState.thinking;
    });
    _scrollToBottom();

    if (understood && transcript.isNotEmpty) {
      _processCommand(transcript);
    } else {
      _speak(transcript);
    }
  }

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
        _speak("Which app do you want to open?");
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
      return;
    }

    // ONLINE AI (Gemini)
    if (_isOnline) {
      Map<String, String>? geminiResponse = await _getGeminiResponse(rawText);

      if (geminiResponse == null) {
        _speak(
            "My AI brain connection failed. I can help with offline tasks like opening apps or making calls.");
        return;
      }

      String spokenResponse =
          geminiResponse['spoken'] ?? "I found something, check your screen.";
      String displayData = geminiResponse['display'] ?? "";

      // Add assistant spoken message to chat
      setState(() {
        _chatHistory.add(ChatMessage(spokenResponse));
      });
      _scrollToBottom();

      _speak(spokenResponse);

      if (displayData.isNotEmpty) {
        setState(() {
          _chatHistory.add(ChatMessage(displayData, isCodeBlock: true));
        });
        _scrollToBottom();
      }
    } else {
      _speak(
          "I'm offline. I can help with offline tasks like opening apps or making calls.");
    }
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
    const String baseUrl =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-09-2025:generateContent?key=";

    // Build minimal history (excluding "Listening...")
    List<Map<String, dynamic>> historyPayload = _chatHistory
        .where((msg) => msg.text != "Listening...")
        .map((msg) {
      return {
        "role": msg.isUser ? "user" : "model",
        "parts": [
          {"text": msg.text}
        ]
      };
    }).toList();

    // Remove last message if it's the user's current prompt (to avoid duplication)
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
                '''You are Jarvis SRS, a helpful AI assistant inside a smart launcher.

Respond in exactly two parts separated by "|||":
- Part 1: A short, conversational reply to be SPOKEN aloud. Do not mention any code or blocks.
- Part 2: The code block or data to DISPLAY on screen. If nothing to display, write ONLY: NONE

Examples:
User: write a python function to add numbers
Assistant: Here is the Python function you asked for.|||```python
def add(a, b):
    return a + b