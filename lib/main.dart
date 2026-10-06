import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:installed_apps/installed_apps.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaxAiApp());
}

class MaxAiApp extends StatelessWidget {
  const MaxAiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'MAX JARVIS AGENT',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF020406),
          colorScheme: const ColorScheme.dark(primary: Colors.amberAccent),
        ),
        home: const HomeScreen(),
      );
}

class AiException implements Exception {
  final String message;
  AiException(this.message);
  @override
  String toString() => message;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  late AnimationController _anim;

  bool _speechReady = false, _isListening = false, _isLoading = false;
  bool _standbyMode = false, _commandMode = false, _speaking = false;
  bool _processing = false, _starting = false;
  int _speakGen = 0;

  String _userSpeech = "", _actionLog = "", _aiLabel = "";
  String _aiResponse = "JARVIS AGENT ONLINE. Boliye, kya kaam karna hai, Boss?";
  String _role = "Boss", _provider = "auto", _geminiKey = "", _groqKey = "";

  List<Contact>? _contactsCache;
  List<dynamic>? _appsCache;

  final List<Map<String, String>> _history = [];
  List<String> _memory = [];
  List<String> _notes = [];

  static const _wakeWords = [
    'hello power', 'hello pawar', 'hello powar', 'hallo power',
    'helo power', 'hey power', 'hello paawar', 'hello pavar',
  ];
  static const _infoTools = {'weather', 'web_search', 'now', 'read_notes', 'lookup_number'};

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _initTts();
    _loadSettings();
    [Permission.microphone, Permission.camera, Permission.phone, Permission.contacts].request();
  }

  @override
  void dispose() {
    _anim.dispose();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage("hi-IN");
      await _tts.setPitch(0.9);
      await _tts.setSpeechRate(0.5);
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
  }

  Future<void> _initSpeech() async {
    try {
      _speechReady = await _speech.initialize(onStatus: _onStatus, onError: _onError);
    } catch (_) {
      _speechReady = false;
    }
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _role = p.getString('user_role') ?? "Boss";
      _provider = p.getString('provider') ?? "auto";
      _geminiKey = (p.getString('gemini_api_key') ?? "").trim();
      _groqKey = (p.getString('groq_api_key') ?? "").trim();
      _memory = p.getStringList('memory') ?? [];
      _notes = p.getStringList('notes') ?? [];
    });
  }

  Future<void> _persistLists() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('memory', _memory);
    await p.setStringList('notes', _notes);
  }

  Future<void> _saveSettings(String role, String provider, String g, String q) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('user_role', role);
    await p.setString('provider', provider);
    await p.setString('gemini_api_key', g.trim());
    await p.setString('groq_api_key', q.trim());
    setState(() {
      _role = role;
      _provider = provider;
      _geminiKey = g.trim();
      _groqKey = q.trim();
    });
  }

  void _onStatus(String s) {
    if (s == 'done' || s == 'notListening') {
      if (mounted) setState(() => _isListening = false);
      _restartStandby(const Duration(milliseconds: 400));
    }
  }

  void _onError(dynamic e) {
    if (mounted) setState(() => _isListening = false);
    _restartStandby(const Duration(milliseconds: 1500));
  }

  void _restartStandby(Duration d) {
    if (!_standbyMode) return;
    Future.delayed(d, () {
      if (mounted && _standbyMode && !_speech.isListening && !_speaking && !_processing && !_starting) {
        _listen(command: false);
      }
    });
  }

  Future<void> _listen({required bool command}) async {
    if (_starting) return;
    if (!_speechReady) await _initSpeech();
    if (!_speechReady) {
      _say("Mic ya speech permission nahi mili, $_role.");
      return;
    }
    if (_speech.isListening) return;
    _starting = true;
    _commandMode = command;
    if (command && mounted) setState(() { _userSpeech = ""; _aiResponse = "Sun raha hoon..."; });
    try {
      await _speech.listen(
        onResult: _onResult,
        localeId: 'en_IN',
        listenFor: Duration(seconds: command ? 20 : 60),
        pauseFor: Duration(seconds: command ? 3 : 4),
        listenOptions: stt.SpeechListenOptions(partialResults: true, cancelOnError: false),
      );
      if (mounted) setState(() => _isListening = true);
    } catch (_) {
      if (mounted) setState(() => _isListening = false);
    } finally {
      _starting = false;
    }
  }

  void _onResult(stt.SpeechRecognitionResult r) {
    final words = r.recognizedWords.trim();
    if (mounted) setState(() => _userSpeech = words);
    if (!r.finalResult || words.isEmpty) return;
    if (_commandMode) {
      _commandMode = false;
      _process(words);
      return;
    }
    final lower = words.toLowerCase();
    for (final w in _wakeWords) {
      final i = lower.indexOf(w);
      if (i >= 0) {
        final rest = lower.substring(i + w.length).trim();
        if (rest.length > 2) {
          _process(rest);
        } else {
          _say("Boliye $_role, main sun raha hoon.", listenNext: true);
        }
        return;
      }
    }
  }

  void _toggleStandby() {
    setState(() => _standbyMode = !_standbyMode);
    if (_standbyMode) {
      _say("Standby on ho gaya, $_role. 'Hello Power' bolkar bulaiye.");
    } else {
      _commandMode = false;
      _speech.stop();
      setState(() => _isListening = false);
      _say("Standby off kar diya.");
    }
  }

  void _onMicTap() {
    if (_speech.isListening) {
      _commandMode = false;
      _speech.stop();
    } else {
      _tts.stop();
      _listen(command: true);
    }
  }

  Future<void> _say(String text, {bool listenNext = false}) async {
    final gen = ++_speakGen;
    if (mounted) setState(() { _isLoading = false; _aiResponse = text; });
    _speaking = true;
    try {
      if (_speech.isListening) await _speech.stop();
      await _tts.stop();
      await _tts.speak(text.replaceAll(RegExp(r'[*#`_~]'), ''));
    } catch (_) {}
    if (gen != _speakGen) return;
    _speaking = false;
    if (!mounted) return;
    if (listenNext) {
      _listen(command: true);
    } else if (_standbyMode) {
      _listen(command: false);
    }
  }

  Future<void> _process(String text) async {
    if (_processing) return;
    _processing = true;
    try {
      final t = text.toLowerCase();
      if (RegExp(r'\b(chup|stop speaking|shut up|bas karo)\b').hasMatch(t)) {
        await _tts.stop();
      } else {
        await _agent(text);
      }
    } catch (_) {
      await _say("Kuch gadbad ho gayi, $_role. Dobara try karein.");
    } finally {
      _processing = false;
      _restartStandby(const Duration(milliseconds: 600));
    }
  }

  Future<void> _agent(String text) async {
    if (_geminiKey.isEmpty && _groqKey.isEmpty) {
      await _say("Pehle settings icon par click karke apni API key daaliye, $_role.");
      return;
    }
    if (mounted) setState(() { _isLoading = true; _aiResponse = "Soch raha hoon..."; });
    await _say("Command mil gayi hai, $_role.");
  }

  void _showSettingsDialog(BuildContext context) {
    final TextEditingController roleController = TextEditingController(text: _role);
    final TextEditingController geminiController = TextEditingController(text: _geminiKey);
    final TextEditingController groqController = TextEditingController(text: _groqKey);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0A0E21),
        title: const Text('Jarvis Settings & API Keys', style: TextStyle(color: Colors.amberAccent)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: roleController,
                decoration: const InputDecoration(labelText: 'Aapka Naam / Role (e.g. Boss)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: geminiController,
                decoration: const InputDecoration(labelText: 'Gemini API Key'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: groqController,
                decoration: const InputDecoration(labelText: 'Groq API Key (Optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent),
            onPressed: () {
              _saveSettings(
                roleController.text.trim(),
                _provider,
                geminiController.text.trim(),
                groqController.text.trim(),
              );
              Navigator.pop(context);
              _say("Settings save ho gayi hain, $_role.");
            },
            child: const Text('Save', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MAX JARVIS AGENT'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: Icon(_standbyMode ? Icons.power : Icons.power_off,
                color: _standbyMode ? Colors.amberAccent : Colors.grey),
            onPressed: _toggleStandby,
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.amberAccent),
            onPressed: () => _showSettingsDialog(context),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.amberAccent.withOpacity(0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      _aiResponse,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, color: Colors.amberAccent),
                    ),
                    if (_actionLog.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(_actionLog, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 30),
              if (_userSpeech.isNotEmpty)
                Text("You said: \"$_userSpeech\"",
                    style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _onMicTap,
        backgroundColor: Colors.amberAccent,
        child: Icon(_isListening ? Icons.mic : Icons.mic_none, color: Colors.black),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
