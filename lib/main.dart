import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'package:picovoice_flutter/picovoice_manager.dart';
import 'package:picovoice_flutter/picovoice_error.dart';

import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';

import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';

// --- Platform Channel Implementation for ORCA TTS ---
class OrcaTTS {
  static const platform = MethodChannel('com.jarvis.orca');
  final player = AudioPlayer();
  bool _isInitialized = false;

  Future<void> init(String accessKey) async {
    try {
      await platform.invokeMethod('initOrca', {'accessKey': accessKey});
      _isInitialized = true;
      print("✅ Orca TTS initialized");
    } catch (e) {
      _isInitialized = false;
      print("❌ Orca Init Error: $e");
    }
  }

  Future<void> speak(String text) async {
    if (!_isInitialized) {
      print("⚠️ Orca not initialized, skipping speech");
      return;
    }
    await player.stop();
    try {
      final Uint8List? audioData =
          await platform.invokeMethod('speak', {'text': text});
      if (audioData != null && audioData.isNotEmpty) {
        await player.play(BytesSource(audioData));
      }
    } catch (e) {
      print("❌ Orca speak error: $e");
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
    _picovoiceManager?.delete();
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

    if (await Permission.microphone.isGranted) {
      _initPicovoice();
    }
  }

  Future<void> _checkConnectivity() async {
    final dynamic result = await Connectivity().checkConnectivity();
    bool online;
    if (result is List<ConnectivityResult>) {
      online = result.any((r) =>
          r == ConnectivityResult.mobile || r == ConnectivityResult.wifi);
    } else {
      online = result == ConnectivityResult.mobile ||
          result == ConnectivityResult.wifi;
    }
    if (mounted) setState(() => _isOnline = online);
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

    _orcaTTS.player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() => _currentState = _AssistantState.idle);
      _picovoiceManager?.start();
    });
  }

  Future<void> _loadInstalledApps() async {
    try {
      List<AppInfo> apps = await InstalledApps.getInstalledApps(
        true,
        true,
      );

      apps.sort((a, b) =>
          (a.name ?? "").toLowerCase().compareTo((b.name ?? "").toLowerCase()));
      if (mounted) {
        setState(() {
          _installedApps = apps;
        });
      }
    } catch (e) {
      print("❌ Error loading apps: $e");
    }
  }

  void _initPicovoice() async {
    String keywordPath = "assets/keywords/Hey-jarvis_en_android_v3_0_0.ppn";
    String contextPath = "assets/contexts/jarvis_context_en_android_v3_0_0.rhn";

    try {
      _picovoiceManager = await PicovoiceManager.create(
        _picovoiceAccessKey,
        keywordPath,
        _wakeWordCallback,
        contextPath,
        _inferenceCallback,
        processErrorCallback: (error) {
          if (mounted) {
            setState(() {
              _chatHistory.add(ChatMessage("Picovoice error: ${error.message}"));
              _currentState = _AssistantState.error;
            });
          }
        },
      );

      await _picovoiceManager?.start();
      if (mounted) {
        setState(() {
          _chatHistory.add(ChatMessage("Say 'Hey Jarvis' or swipe up for apps..."));
        });
      }
    } on PicovoiceException catch (err) {
      if (mounted) {
        setState(() {
          _chatHistory.add(ChatMessage("Failed to init Picovoice: ${err.message}"));
          _currentState = _AssistantState.error;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _chatHistory.add(ChatMessage("Unexpected error: $e"));
          _currentState = _AssistantState.error;
        });
      }
    }
  }

  void _wakeWordCallback() {
    if (_currentState == _AssistantState.idle) {
      if (mounted) {
        setState(() {
          _currentState = _AssistantState.listening;
          _chatHistory.add(ChatMessage("Listening...", isUser: true));
          _scrollToBottom();
        });
      }
    }
  }

  void _inferenceCallback(Map<String, dynamic> inference) {
    String transcript = "";
    bool understood = false;

    if (inference.containsKey('isUnderstood') && inference['isUnderstood'] == true) {
      transcript = inference['intent'] ?? "";
      understood = true;
    } else if (inference.containsKey('transcript')) {
      transcript = inference['transcript'] ?? "";
      understood = transcript.isNotEmpty;
    }

    if (mounted) {
      setState(() {
        if (_chatHistory.isNotEmpty && _chatHistory.last.text == "Listening...") {
          _chatHistory.removeLast();
        }
        _chatHistory.add(ChatMessage(
            transcript.isNotEmpty ? transcript : "...",
            isUser: true));
        _currentState = _AssistantState.thinking;
        _scrollToBottom();
      });
    }

    if (understood && transcript.isNotEmpty) {
      _processCommand(transcript);
    } else {
      _speak("I didn't catch that. Please try again.");
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
    if (text.isEmpty) {
      _picovoiceManager?.start();
      return;
    }

    _picovoiceManager?.stop();

    if (mounted) {
      setState(() => _currentState = _AssistantState.speaking);
      _chatHistory.add(ChatMessage(text, isUser: false));
      _scrollToBottom();
    }
    _orcaTTS.speak(text);
  }

  Future<void> _processCommand(String rawText) async {
    String command = rawText.toLowerCase().trim();

    if (command.startsWith("open") || command.startsWith("launch")) {
      String appName = command
          .replaceFirst("open", "")
          .replaceFirst("launch", "")
          .trim();
      if (appName.isNotEmpty) {
        _openApp(appName);
      } else {
        _speak("Which app should I open?");
      }
      return;
    }

    if (command.startsWith("call") || command.startsWith("phone")) {
      String contactName =
          command.replaceFirst("call", "").replaceFirst("phone", "").trim();
      if (contactName.isNotEmpty) {
        _makeCall(contactName);
      } else {
        _speak("Who do you want to call?");
      }
      return;
    }

    if (command.contains("show all apps") ||
        command.contains("open app drawer") ||
        command.contains("show apps")) {
      _openAppDrawer();
      if (mounted) setState(() => _currentState = _AssistantState.idle);
      _picovoiceManager?.start();
      return;
    }

    if (_isOnline) {
      Map<String, String>? geminiResponse = await _getGeminiResponse(rawText);

      if (geminiResponse == null) {
        _speak("I'm having trouble connecting to my brain right now.");
        return;
      }

      String spokenResponse = geminiResponse['spoken'] ?? "Here is what I found.";
      String displayData = geminiResponse['display'] ?? "";

      _speak(spokenResponse);

      if (displayData.isNotEmpty && mounted) {
        setState(() {
          _chatHistory.add(ChatMessage(displayData, isCodeBlock: true));
        });
        _scrollToBottom();
      }
    } else {
      _speak("I'm offline. I can open apps or make calls.");
    }
  }

  void _openApp(String appName) {
    try {
      final app = _installedApps.firstWhere(
        (a) => (a.name ?? "").toLowerCase().contains(appName.toLowerCase()),
      );
      if (app.packageName != null) {
        InstalledApps.startApp(app.packageName!);
        _speak("Opening ${app.name}");
      }
      if (mounted) setState(() => _currentState = _AssistantState.idle);
      _picovoiceManager?.start();
    } catch (e) {
      _speak("I couldn't find an app named $appName.");
    }
  }

  void _openAppDrawer() {
    _picovoiceManager?.stop();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => AppDrawerScreen(apps: _installedApps)),
    ).then((_) {
      _picovoiceManager?.start();
      if (mounted) setState(() => _currentState = _AssistantState.idle);
    });
  }

  Future<void> _makeCall(String contactName) async {
    if (await Permission.contacts.isGranted && await Permission.phone.isGranted) {
      _speak("Searching for $contactName");

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
          _speak("Calling ${targetContact.displayName}");
          await FlutterPhoneDirectCaller.callNumber(number);
          if (mounted) setState(() => _currentState = _AssistantState.idle);
          _picovoiceManager?.start();
        } else {
          _speak("Sorry, I couldn't find that contact.");
        }
      } catch (e) {
        _speak("Error accessing contacts.");
      }
    } else {
      _speak("I need contact and phone permissions first.");
      await _requestPermissions();
    }
  }

  Future<Map<String, String>?> _getGeminiResponse(String prompt) async {
    final String url =
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=$_geminiApiKey";

    List<Map<String, dynamic>> historyPayload = _chatHistory
        .where((msg) =>
            msg.text != "Listening..." &&
            !msg.text.startsWith("Say 'Hey") &&
            !msg.isCodeBlock)
        .map((msg) {
      return {
        "role": msg.isUser ? "user" : "model",
        "parts": [
          {"text": msg.text}
        ]
      };
    }).toList();

    if (historyPayload.length > 10) {
      historyPayload = historyPayload.sublist(historyPayload.length - 10);
    }
    if (historyPayload.isNotEmpty && historyPayload.last["role"] == "user") {
      historyPayload.removeLast();
    }

    String systemPrompt =
        "You are Jarvis SRS, a helpful voice assistant. "
        "Respond in exactly two parts separated by '|||': "
        "Part 1: Spoken reply (conversational, no markdown). "
        "Part 2: Screen display (use markdown/code if needed, or 'NONE' if empty).";

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
          {"text": systemPrompt}
        ]
      }
    });

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String fullText =
            data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? "";

        final parts = fullText.split("|||");
        String spoken = parts[0].trim();
        String display = parts.length > 1 ? parts[1].trim() : "";
        if (display == "NONE") display = "";

        return {'spoken': spoken, 'display': display};
      } else {
        print("❌ Gemini Error: ${response.statusCode} - ${response.body}");
      }
    } catch (e) {
      print("❌ Gemini Network Error: $e");
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1E),
      body: GestureDetector(
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null && details.primaryVelocity! < -300) {
            _openAppDrawer();
          }
        },
        child: Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Column(
            children: [
              if (!_isOnline)
                Container(
                  color: Colors.amber[800],
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4) +
                      EdgeInsets.only(top: MediaQuery.of(context).padding.top),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off, size: 14, color: Colors.white),
                      SizedBox(width: 8),
                      Text("Offline Mode", style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _chatHistory.length,
                  padding: EdgeInsets.only(
                      top: _isOnline ? 24 : 0, left: 16, right: 16),
                  itemBuilder: (context, index) {
                    final message = _chatHistory[index];
                    if (message.isCodeBlock) {
                      return _buildCodeBubble(message);
                    } else {
                      return _buildChatBubble(message);
                    }
                  },
                ),
              ),
              _buildCurrentStateVisualizer(),
              if (_currentState == _AssistantState.idle)
                const Padding(
                  padding: EdgeInsets.only(bottom: 20.0),
                  child: Column(
                    children: [
                      Icon(Icons.keyboard_arrow_up, color: Colors.white38, size: 28),
                      Text("Swipe up for apps",
                          style: TextStyle(color: Colors.white38, fontSize: 14)),
                    ],
                  ),
                )
              else
                const SizedBox(height: 70),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCodeBubble(ChatMessage message) {
    String rawCode = message.text
        .replaceAll("```python", "")
        .replaceAll("```java", "")
        .replaceAll("```dart", "")
        .replaceAll("```javascript", "")
        .replaceAll("```", "")
        .trim();

    String language = "dart";
    if (message.text.contains("```python")) language = "python";
    if (message.text.contains("```java")) language = "java";
    if (message.text.contains("```javascript")) language = "javascript";

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A3A59)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF2A3A59),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  language,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: rawCode)).then((_) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Code copied to clipboard!"),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    });
                  },
                )
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                rawCode,
                style: const TextStyle(
                  fontSize: 14,
                  fontFamily: 'monospace',
                  color: Colors.greenAccent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatBubble(ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: message.isUser
              ? Theme.of(context).primaryColor
              : const Color(0xFF2A3A59),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          message.text,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildCurrentStateVisualizer() {
    switch (_currentState) {
      case _AssistantState.listening:
        return const ListeningWaveform();
      case _AssistantState.thinking:
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Theme.of(context).primaryColor),
              ),
              const SizedBox(width: 12),
              Text("Jarvis is thinking...",
                  style: TextStyle(color: Colors.blue[200], fontSize: 16)),
            ],
          ),
        );
      case _AssistantState.speaking:
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text("Jarvis is speaking...",
              style: TextStyle(color: Colors.greenAccent[400], fontSize: 16)),
        );
      case _AssistantState.error:
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text("An error occurred. Please restart.",
              style: TextStyle(color: Colors.redAccent[400], fontSize: 16)),
        );
      case _AssistantState.idle:
      default:
        return const SizedBox(height: 70);
    }
  }
}

class ListeningWaveform extends StatefulWidget {
  const ListeningWaveform({super.key});

  @override
  State<ListeningWaveform> createState() => _ListeningWaveformState();
}

class _ListeningWaveformState extends State<ListeningWaveform>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          height: 70,
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(15, (index) {
              return Container(
                width: 4,
                height: 10 + _random.nextDouble() * 40,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

class AppDrawerScreen extends StatelessWidget {
  final List<AppInfo> apps;

  const AppDrawerScreen({super.key, required this.apps});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1E),
      appBar: AppBar(
        title: const Text("All Apps"),
        centerTitle: true,
        backgroundColor: const Color(0xFF161D30),
      ),
      body: apps.isEmpty
          ? const Center(
              child: Text("No apps found.", style: TextStyle(color: Colors.white)))
          : GridView.builder(
              padding: const EdgeInsets.all(16.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 16.0,
                mainAxisSpacing: 16.0,
                childAspectRatio: 0.8,
              ),
              itemCount: apps.length,
              itemBuilder: (context, index) {
                AppInfo app = apps[index];
                return InkWell(
                  onTap: () {
                    if (app.packageName != null) {
                      InstalledApps.startApp(app.packageName!);
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      app.icon != null
                          ? Image.memory(app.icon!, width: 48, height: 48)
                          : const Icon(Icons.android, size: 48, color: Colors.white),
                      const SizedBox(height: 8),
                      Text(
                        app.name ?? "Unknown",
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}