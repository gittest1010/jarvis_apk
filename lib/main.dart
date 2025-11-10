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
import 'package:flutter_syntax_highlighter/flutter_syntax_highlighter.dart';
import 'package:clipboard/clipboard.dart';

/// ORCA TTS Helper
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

void main() async {
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
        ).copyWith(secondary: const Color(0xFF00BFFF)),
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
  final String _picovoiceAccessKey = "YOUR_PICOVOICE_ACCESS_KEY_HERE";
  final String _geminiApiKey = "YOUR_GEMINI_API_KEY_HERE";

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
    _loadInstalledApps();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.contacts,
      Permission.phone,
      Permission.storage,
    ].request();
  }

  Future<void> _initPicovoice() async {
    String keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    String contextPath = "assets/models/cheetah_params.pv";

    try {
      _picovoiceManager = await PicovoiceManager.create(
        _picovoiceAccessKey,
        keywordPath,
        _wakeWordCallback,
        contextPath,
        _inferenceCallback,
        (error) {
          setState(() {
            _chatHistory.add(ChatMessage("Picovoice error: ${error.message}"));
            _currentState = _AssistantState.error;
          });
        },
      );
      await _picovoiceManager?.start();
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

  Future<void> _initTts() async {
    _orcaTTS = OrcaTTS();
    try {
      await _orcaTTS.init(_picovoiceAccessKey);
      _orcaTTS.player.onPlayerComplete.listen((_) {
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
      transcript = inference['transcript'] ?? "";
      understood = true;
    }

    setState(() {
      if (_chatHistory.isNotEmpty && _chatHistory.last.text == "Listening...") {
        _chatHistory.removeLast();
      }
      _chatHistory.add(ChatMessage(transcript, isUser: true));
      _currentState = _AssistantState.thinking;
      _scrollToBottom();
    });

    understood ? _processCommand(transcript) : _speak(transcript);
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

  void _loadInstalledApps() async {
    List<AppInfo> apps =
        await InstalledApps.getInstalledApps(true, true);
    apps.sort((a, b) => a.name!.toLowerCase().compareTo(b.name!.toLowerCase()));
    setState(() => _installedApps = apps);
  }

  Future<void> _processCommand(String rawText) async {
    String command = rawText.toLowerCase();

    if (command.startsWith("open") || command.startsWith("launch")) {
      String appName =
          command.replaceFirst("open", "").replaceFirst("launch", "").trim();
      appName.isNotEmpty ? _openApp(appName) : _speak("Which app do you want?");
      return;
    }

    if (command.startsWith("call") || command.startsWith("phone")) {
      String contactName =
          command.replaceFirst("call", "").replaceFirst("phone", "").trim();
      contactName.isNotEmpty
          ? _makeCall(contactName)
          : _speak("Who do you want to call?");
      return;
    }

    if (command.contains("show all apps") || command.contains("open app drawer")) {
      _openAppDrawer();
      setState(() => _currentState = _AssistantState.idle);
      return;
    }

    if (_isOnline) {
      Map<String, String>? geminiResponse = await _getGeminiResponse(rawText);
      if (geminiResponse == null) {
        _speak("My AI brain connection failed. Offline mode active.");
        return;
      }
      String spoken = geminiResponse['spoken'] ?? "Here’s what I found.";
      String display = geminiResponse['display'] ?? "";
      _speak(spoken);
      if (display.isNotEmpty) {
        setState(() {
          _chatHistory.add(ChatMessage(display, isCodeBlock: true));
          _scrollToBottom();
        });
      }
    } else {
      _speak("I'm offline. I can only open apps or make calls.");
    }
  }

  Future<void> _speak(String text) async {
    await _orcaTTS.speak(text);
  }

  Future<void> _openApp(String appName) async {
    for (var app in _installedApps) {
      if (app.name!.toLowerCase().contains(appName)) {
        await InstalledApps.startApp(app.packageName!);
        return;
      }
    }
    _speak("I couldn’t find $appName.");
  }

  void _openAppDrawer() {
    showModalBottomSheet(
      context: context,
      builder: (_) => ListView(
        children: _installedApps
            .map((a) => ListTile(
                  title: Text(a.name ?? 'Unknown App'),
                  onTap: () => InstalledApps.startApp(a.packageName!),
                ))
            .toList(),
      ),
    );
  }

  Future<void> _makeCall(String contactName) async {
    if (await Permission.contacts.isGranted &&
        await Permission.phone.isGranted) {
      _speak("Searching for $contactName...");
      try {
        List<Contact> contacts =
            await FlutterContacts.getContacts(withProperties: true);
        Contact? target = contacts.firstWhere(
            (c) => c.displayName.toLowerCase().contains(contactName),
            orElse: () => Contact());
        if (target.phones.isNotEmpty) {
          String number = target.phones.first.number;
          _speak("Calling ${target.displayName}...");
          await FlutterPhoneDirectCaller.callNumber(number);
        } else {
          _speak("No number found for ${target.displayName}");
        }
      } catch (e) {
        _speak("Error reading contacts.");
      }
    } else {
      _speak("I need permission to make calls.");
      await _requestPermissions();
    }
  }

  Future<Map<String, String>?> _getGeminiResponse(String prompt) async {
    const String url =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-09-2025:generateContent?key=";

    final body = jsonEncode({
      "contents": [
        {"role": "user", "parts": [{"text": prompt}]}
      ],
      "systemInstruction": {
        "parts": [
          {
            "text":
                "You are Jarvis SRS, a launcher voice assistant. Always reply in two parts separated by '|||'. "
                    "Part 1: Short spoken reply. Part 2: data/code to display or 'NONE'. "
                    "Example: 'Here’s your Python code.|||```python\\ndef add(a,b):\\n    return a+b\\n```'"
          }
        ]
      }
    });

    final response = await http.post(
      Uri.parse("$url$_geminiApiKey"),
      headers: {"Content-Type": "application/json"},
      body: body,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final text =
          data["candidates"]?[0]?["content"]?["parts"]?[0]?["text"] ?? "";
      if (text.contains("|||")) {
        final parts = text.split("|||");
        return {"spoken": parts[0].trim(), "display": parts[1].trim()};
      } else {
        return {"spoken": text.trim(), "display": ""};
      }
    } else {
      return null;
    }
  }
}
