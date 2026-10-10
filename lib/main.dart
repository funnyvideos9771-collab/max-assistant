import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'gemini_service.dart';
import 'page_viewer.dart';

// ─────────────────────────────────────────────────────────────
// Theme tokens
// ─────────────────────────────────────────────────────────────
const Color kBlack = Color(0xFF000000);
const Color kPanel = Color(0xFF110A02);
const Color kOrange = Color(0xFFFF6D00);
const Color kAmber = Color(0xFFFFA000);
const Color kGold = Color(0xFFFFD54F);
const Color kError = Color(0xFFFF5252);

// ─────────────────────────────────────────────────────────────
// Assistant controller (state + speech + API)
// ─────────────────────────────────────────────────────────────
enum Phase { idle, listening, thinking, speaking }

class ChatMessage {
  ChatMessage(this.fromUser, this.text);
  final bool fromUser;
  final String text;
}

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

class AssistantController extends ChangeNotifier {
  AssistantController() {
    _init();
  }

  static const String _defaultVoiceId = '21m00Tcm4TlvDq8ikWAM';
  static const String _prefKey = 'gemini_api_key';
  static const String _prefStandby = 'standby_enabled';
  static const String _envKey = String.fromEnvironment('GEMINI_API_KEY');
  static final RegExp _wakePattern = RegExp(r'(hello|hallo|हेलो|हैलो)\s*(p(ow|aw|av|ou)|पावर|पवार)');

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final GeminiService _gemini = GeminiService();

  Phase phase = Phase.idle;
  String status = 'Initializing…';
  bool isError = false;
  bool standby = false;
  String command = 'hello';
  String reply = '';
  String apiKey = '';
  String assistantName = 'Riya';
  double voicePitch = 1.3;
  double voiceRate = 0.48;
  String? voiceName;
  String elevenKey = '';
  String elevenVoiceId = _defaultVoiceId;
  String listenLang = 'hi_IN';
  String actionLog = '';
  String voiceNote = '';
  bool _hiTts = false;
  final AudioPlayer _player = AudioPlayer();
  final Map<String, Uint8List> _audioCache = {};
  String? get _localeId => listenLang.isEmpty ? null : listenLang;
  final List<ChatMessage> chat = [];

  bool _sttReady = false;
  bool _wakeListening = false;
  bool _commandHandled = false;
  bool _disposed = false;
  String _lastWords = '';

  bool get hasKey => apiKey.trim().isNotEmpty;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(Phase p, String s, {bool error = false}) {
    phase = p;
    status = s;
    isError = error;
    _notify();
  }

  void _setIdle(String s, {bool error = false, int wakeDelayMs = 700}) {
    _set(Phase.idle, s, error: error);
    _scheduleWake(wakeDelayMs);
  }

  Future<void> _init() async {
    _gemini.onAction = (s) {
      actionLog = s;
      _notify();
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      apiKey = prefs.getString(_prefKey) ?? _envKey;
      standby = prefs.getBool(_prefStandby) ?? false;
      assistantName = prefs.getString('assistant_name') ?? 'Riya';
      voicePitch = prefs.getDouble('voice_pitch') ?? 1.3;
      voiceRate = prefs.getDouble('voice_rate') ?? 0.48;
      voiceName = prefs.getString('voice_name');
      elevenKey = prefs.getString('eleven_key') ?? const String.fromEnvironment('ELEVEN_API_KEY');
      elevenVoiceId = prefs.getString('eleven_voice') ?? _defaultVoiceId;
      listenLang = prefs.getString('listen_lang') ?? 'hi_IN';
      _gemini.assistantName = assistantName;
    } catch (_) {
      apiKey = _envKey;
    }

    try {
      await _tts.awaitSpeakCompletion(true);
      final hi = await _tts.isLanguageAvailable('hi-IN');
      await _tts.setLanguage(hi == true ? 'hi-IN' : 'en-US');
      _hiTts = hi == true;
      await applyVoice();
    } catch (_) {
      // TTS is optional; the UI still shows replies as text.
    }

    await _initSpeech();

    if (!_sttReady) {
      _set(Phase.idle,
          'Microphone or speech service unavailable. Allow microphone access and install Google speech services.',
          error: true);
    } else if (!hasKey) {
      _set(Phase.idle, 'API key missing. Open Settings to add your Gemini key.',
          error: true);
    } else {
      _setIdle(standby
          ? 'Standby active. Say "Hello Power".'
          : 'Ready. Tap the arc reactor to give a command.');
    }
  }

  Future<void> applyVoice() async {
    try {
      if (voiceName != null && voiceName!.contains('|')) {
        final p = voiceName!.split('|');
        await _tts.setVoice({'name': p[0], 'locale': p[1]});
      }
      await _tts.setSpeechRate(voiceRate);
      await _tts.setPitch(voicePitch);
      _gemini.devanagari = elevenKey.trim().isNotEmpty || _hiTts;
    } catch (_) {}
  }

  Future<List<Map<String, String>>> listVoices() async {
    try {
      final raw = await _tts.getVoices;
      final out = <Map<String, String>>[];
      if (raw is List) {
        for (final v in raw) {
          if (v is! Map) continue;
          final loc = (v['locale'] ?? '').toString();
          if (loc.startsWith('hi') || loc.startsWith('en-IN') || loc.startsWith('en_IN')) {
            out.add({'name': v['name'].toString(), 'locale': loc});
          }
        }
      }
      out.sort((a, b) => a['name']!.compareTo(b['name']!));
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveVoice({String? voice, double? pitch, double? rate, String? name}) async {
    if (voice != null) voiceName = voice;
    if (pitch != null) voicePitch = pitch;
    if (rate != null) voiceRate = rate;
    if (name != null) {
      assistantName = name.trim().isEmpty ? 'Riya' : name.trim();
      _gemini.assistantName = assistantName;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('assistant_name', assistantName);
      await prefs.setDouble('voice_pitch', voicePitch);
      await prefs.setDouble('voice_rate', voiceRate);
      if (voiceName != null) await prefs.setString('voice_name', voiceName!);
    } catch (_) {}
    await applyVoice();
  }

  Future<void> saveEleven({String? key, String? voiceId}) async {
    if (key != null) elevenKey = key.trim();
    if (voiceId != null) {
      elevenVoiceId = voiceId.trim().isEmpty ? _defaultVoiceId : voiceId.trim();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('eleven_key', elevenKey);
      await prefs.setString('eleven_voice', elevenVoiceId);
    } catch (_) {}
    voiceNote = '';
    await applyVoice();
  }

  Future<void> saveListenLang(String lang) async {
    listenLang = lang;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('listen_lang', lang);
    } catch (_) {}
    _notify();
  }

  Future<void> previewVoice() =>
      _speak('हाय बॉस, मैं $assistantName हूँ। बताइए, आज क्या करना है?');

  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || phase != Phase.idle) return;
    _wakeListening = false;
    try {
      if (_stt.isListening) await _stt.cancel();
    } catch (_) {}
    command = t;
    await _process(t);
  }

  Future<void> _initSpeech() async {
    try {
      _sttReady = await _stt.initialize(
        onError: _onError,
        onStatus: _onStatus,
      );
    } catch (_) {
      _sttReady = false;
    }
  }

  // ── Settings ──
  Future<void> saveApiKey(String key) async {
    apiKey = key.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, apiKey);
    } catch (_) {}
    if (phase == Phase.idle) {
      if (hasKey) {
        _setIdle('API key saved. Tap the arc reactor to give a command.');
      } else {
        _set(Phase.idle, 'API key missing. Open Settings to add your Gemini key.',
            error: true);
      }
    }
  }

  Future<void> setStandby(bool value) async {
    standby = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefStandby, value);
    } catch (_) {}

    if (value) {
      if (phase == Phase.idle) {
        _setIdle('Standby active. Say "Hello Power".', wakeDelayMs: 200);
      } else {
        _notify();
      }
    } else {
      _wakeListening = false;
      if (phase == Phase.idle) {
        try {
          await _stt.cancel();
        } catch (_) {}
        _set(Phase.idle, 'Standby off. Tap the arc reactor to give a command.');
      } else {
        _notify();
      }
    }
  }

  // ── Reactor tap ──
  Future<void> onReactorTap() async {
    if (!_sttReady) {
      await _initSpeech();
      if (!_sttReady) {
        _set(Phase.idle,
            'Microphone permission denied or speech service missing. Enable it in Android settings.',
            error: true);
        return;
      }
    }
    switch (phase) {
      case Phase.idle:
        await _startCommand();
        break;
      case Phase.listening:
        try {
          await _stt.stop();
        } catch (_) {}
        break;
      case Phase.speaking:
        try {
          await _tts.stop();
          await _player.stop();
        } catch (_) {}
        _setIdle('Stopped. Tap the arc reactor to give a command.');
        break;
      case Phase.thinking:
        break;
    }
  }

  // ── Command flow ──
  Future<void> _startCommand() async {
    _wakeListening = false;
    try {
      if (_stt.isListening) await _stt.cancel();
    } catch (_) {}

    _commandHandled = false;
    _lastWords = '';
    _set(Phase.listening, 'Listening… speak now, Boss.');

    try {
      await _stt.listen(
        onResult: _onCommandResult,
        localeId: _localeId,
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      _setIdle('Could not start the microphone. Try again.', error: true);
    }
  }

  void _onCommandResult(SpeechRecognitionResult result) {
    if (phase != Phase.listening) return;
    _lastWords = result.recognizedWords;
    if (_lastWords.isNotEmpty) command = _lastWords;
    _notify();
    if (result.finalResult) _handleCommand();
  }

  void _handleCommand() {
    if (_commandHandled) return;
    _commandHandled = true;
    final text = _lastWords.trim();
    if (text.isEmpty) {
      _setIdle('Did not catch that. Tap the arc reactor and try again.');
      return;
    }
    _process(text);
  }

  Future<void> _process(String text) async {
    chat.add(ChatMessage(true, text));
    actionLog = '';
    _set(Phase.thinking, 'Contacting Gemini…');
    try {
      final answer = await _gemini.ask(text, apiKey);
      reply = answer;
      chat.add(ChatMessage(false, answer));
      _set(Phase.speaking, 'Speaking…');
      await _speak(answer);
      if (phase == Phase.speaking) {
        _setIdle(standby
            ? 'Standby active. Say "Hello Power".'
            : 'Ready. Tap the arc reactor to give a command.');
      }
    } on GeminiException catch (e) {
      reply = '';
      _set(Phase.speaking, e.message, error: true);
      await _speak('सॉरी बॉस, यह नहीं हो पाया।');
      _setIdle(e.message, error: true);
    } catch (_) {
      reply = '';
      _setIdle('Something went wrong. Please try again.', error: true);
    }
  }

  String _elevenError(int code) {
    switch (code) {
      case 401:
        return 'ElevenLabs key invalid (401). Using phone voice.';
      case 402:
      case 403:
        return 'ElevenLabs plan does not allow this voice ($code). Use a premade voice ID. Using phone voice.';
      case 404:
        return 'ElevenLabs voice ID not found (404). Using phone voice.';
      case 429:
        return 'ElevenLabs quota or rate limit (429). Using phone voice.';
      default:
        return 'ElevenLabs error ($code). Using phone voice.';
    }
  }

  Future<bool> _speakEleven(String text) async {
    try {
      final cacheKey = '$elevenVoiceId|$text';
      Uint8List? bytes = _audioCache[cacheKey];
      if (bytes == null) {
        final res = await http
            .post(
              Uri.https('api.elevenlabs.io', '/v1/text-to-speech/$elevenVoiceId',
                  {'output_format': 'mp3_44100_128'}),
              headers: {
                'xi-api-key': elevenKey.trim(),
                'Content-Type': 'application/json',
                'Accept': 'audio/mpeg',
              },
              body: jsonEncode({
                'text': text,
                'model_id': 'eleven_multilingual_v2',
                'voice_settings': {
                  'stability': 0.4,
                  'similarity_boost': 0.8,
                  'style': 0.35,
                  'use_speaker_boost': true,
                },
              }),
            )
            .timeout(const Duration(seconds: 25));
        if (res.statusCode != 200) {
          voiceNote = _elevenError(res.statusCode);
          _notify();
          return false;
        }
        bytes = res.bodyBytes;
        if (text.length < 60) _audioCache[cacheKey] = bytes;
      }
      final done = Completer<void>();
      final sub = _player.onPlayerStateChanged.listen((st) {
        if ((st == PlayerState.completed || st == PlayerState.stopped) &&
            !done.isCompleted) {
          done.complete();
        }
      });
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      await done.future.timeout(const Duration(seconds: 120), onTimeout: () {});
      await sub.cancel();
      if (voiceNote.isNotEmpty) {
        voiceNote = '';
        _notify();
      }
      return true;
    } catch (_) {
      voiceNote = 'ElevenLabs unreachable. Using phone voice.';
      _notify();
      return false;
    }
  }

  Future<void> _speak(String text) async {
    try {
      final clean = text.replaceAll(RegExp(r'[*_`#]'), '');
      if (elevenKey.trim().isNotEmpty && await _speakEleven(clean)) return;
      if (!_hiTts && RegExp(r'[\u0900-\u097F]').hasMatch(clean)) {
        voiceNote =
            'Phone has no Hindi voice. Add an ElevenLabs key or install Hindi in Google Text-to-speech.';
        _notify();
      }
      await _tts.speak(clean);
    } catch (_) {}
  }

  // ── Wake word flow ──
  void _scheduleWake(int delayMs) {
    if (!standby || _disposed) return;
    Future.delayed(Duration(milliseconds: delayMs), _startWake);
  }

  Future<void> _startWake() async {
    if (_disposed || !standby || phase != Phase.idle || _wakeListening) return;
    if (!_sttReady) return;
    try {
      if (_stt.isListening) return;
      _wakeListening = true;
      await _stt.listen(
        onResult: _onWakeResult,
        localeId: _localeId,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 8),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      _wakeListening = false;
      _scheduleWake(3000);
    }
  }

  void _onWakeResult(SpeechRecognitionResult result) {
    if (!_wakeListening || phase != Phase.idle) return;
    final heard = result.recognizedWords.toLowerCase();
    if (_wakePattern.hasMatch(heard)) _onWakeDetected();
  }

  Future<void> _onWakeDetected() async {
    _wakeListening = false;
    _set(Phase.speaking, 'Wake word detected.');
    try {
      await _stt.cancel();
    } catch (_) {}
    await _speak('हाँ बॉस, बोलिए?');
    await Future.delayed(const Duration(milliseconds: 200));
    await _startCommand();
  }

  // ── Speech callbacks ──
  void _onStatus(String s) {
    if (s != 'done' && s != 'notListening') return;
    if (phase == Phase.listening) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (phase == Phase.listening) _handleCommand();
      });
    } else if (_wakeListening && phase == Phase.idle) {
      _wakeListening = false;
      _scheduleWake(500);
    }
  }

  void _onError(SpeechRecognitionError e) {
    final benign =
        e.errorMsg == 'error_speech_timeout' || e.errorMsg == 'error_no_match';
    final denied = e.errorMsg == 'error_permission';
    if (e.errorMsg.contains('language')) listenLang = '';

    if (phase == Phase.listening) {
      if (_commandHandled) return;
      if (benign && _lastWords.trim().isNotEmpty) {
        _handleCommand();
        return;
      }
      _commandHandled = true;
      if (denied) {
        _setIdle('Microphone permission denied. Enable it in Android settings.',
            error: true, wakeDelayMs: 5000);
      } else if (benign) {
        _setIdle('Did not catch that. Tap the arc reactor and try again.');
      } else {
        _setIdle('Speech error: ${e.errorMsg}. Try again.', error: true);
      }
    } else if (phase == Phase.idle && _wakeListening) {
      _wakeListening = false;
      _scheduleWake(benign ? 500 : 3000);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stt.cancel();
    _tts.stop();
    _player.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: kBlack,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  pageNotifier.addListener(() {
    final page = pageNotifier.value;
    if (page == null) return;
    pageNotifier.value = null;
    navKey.currentState?.push(
      MaterialPageRoute(builder: (_) => PageViewerScreen(page: page)),
    );
  });
  runApp(
    ChangeNotifierProvider(
      create: (_) => AssistantController(),
      child: const JarvisApp(),
    ),
  );
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
      title: 'JARVIS Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBlack,
        colorScheme: const ColorScheme.dark(
          primary: kAmber,
          secondary: kOrange,
          surface: kPanel,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Home screen
// ─────────────────────────────────────────────────────────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AssistantController>();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            children: [
              _Header(
                onSettings: () => _openSettings(context),
                onHistory: () => _openHistory(context),
              ),
              const SizedBox(height: 16),
              _StandbyCard(controller: c),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final size =
                        math.min(box.maxWidth, box.maxHeight - 40) * 0.92;
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: math.max(size, 120),
                          height: math.max(size, 120),
                          child: ArcReactor(
                            phase: c.phase,
                            onTap: c.onReactorTap,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _hint(c.phase),
                          style: TextStyle(
                            color: kAmber.withValues(alpha: 0.85),
                            fontSize: 14,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              _StatusPanel(controller: c),
            ],
          ),
        ),
      ),
    );
  }

  static String _hint(Phase p) {
    switch (p) {
      case Phase.idle:
        return 'Tap arc reactor to give command';
      case Phase.listening:
        return 'Listening… tap to finish';
      case Phase.thinking:
        return 'Thinking…';
      case Phase.speaking:
        return 'Speaking… tap to stop';
    }
  }

  void _openHistory(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => Consumer<AssistantController>(
          builder: (context, c, _) {
            if (c.chat.isEmpty) {
              return const Center(
                child: Text('No conversation yet.',
                    style: TextStyle(color: Colors.white54)),
              );
            }
            return ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              itemCount: c.chat.length,
              itemBuilder: (_, i) {
                final m = c.chat[i];
                return Align(
                  alignment:
                      m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxWidth: 300),
                    decoration: BoxDecoration(
                      color: m.fromUser
                          ? kOrange.withValues(alpha: 0.25)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: (m.fromUser ? kOrange : kAmber)
                              .withValues(alpha: 0.5)),
                    ),
                    child: Text(m.text,
                        style: const TextStyle(color: Colors.white, height: 1.35)),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AssistantController>(),
        child: const _SettingsDialog(),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onSettings, required this.onHistory});
  final VoidCallback onSettings;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'JARVIS ASSISTANT (Boss)',
              style: TextStyle(
                color: kGold,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                shadows: [Shadow(color: kOrange, blurRadius: 14)],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Chat history',
          onPressed: onHistory,
          icon: const Icon(Icons.forum_outlined, color: kAmber, size: 24),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings, color: kAmber, size: 26),
        ),
      ],
    );
  }
}

class _StandbyCard extends StatelessWidget {
  const _StandbyCard({required this.controller});
  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kAmber.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(color: kOrange.withValues(alpha: 0.18), blurRadius: 18),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.power_settings_new, color: kAmber, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  "Standby Wake Word ('Hello Power')",
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Switch(
                value: controller.standby,
                onChanged: controller.setStandby,
                thumbColor: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.selected) ? kGold : Colors.grey,
                ),
                trackColor: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.selected)
                      ? kOrange.withValues(alpha: 0.6)
                      : Colors.white12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: kBlack,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kOrange.withValues(alpha: 0.5)),
            ),
            child: Text(
              'Command: ${controller.command}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kGold, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});
  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final err = controller.isError;
    final color = err ? kError : kAmber;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 190),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  err ? Icons.error_outline : Icons.graphic_eq,
                  color: color,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    controller.status,
                    style: TextStyle(color: color, fontSize: 14, height: 1.3),
                  ),
                ),
              ],
            ),
            if (controller.actionLog.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('⚙ ${controller.actionLog}',
                  style: const TextStyle(color: kGold, fontSize: 12)),
            ],
            if (controller.voiceNote.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(controller.voiceNote,
                  style: const TextStyle(color: kError, fontSize: 12)),
            ],
            if (controller.reply.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                controller.reply,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, height: 1.35),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Settings dialog
// ─────────────────────────────────────────────────────────────
class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _text;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(
        text: context.read<AssistantController>().apiKey);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kAmber),
      ),
      title: const Text('Settings', style: TextStyle(color: kGold)),
      content: SingleChildScrollView(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _NameAndVoice(),
          const SizedBox(height: 16),
          const Text(
            'Gemini API key (create one at aistudio.google.com/app/apikey). '
            'It is stored only on this device.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'API key',
              labelStyle: const TextStyle(color: kAmber),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: kAmber.withValues(alpha: 0.5)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: kGold),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility : Icons.visibility_off,
                  color: kAmber,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      )),
      actions: [

        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await context.read<AssistantController>().saveApiKey(_text.text);
            navigator.pop();
          },
          child: const Text('Save', style: TextStyle(color: kGold)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Arc reactor
// ─────────────────────────────────────────────────────────────
class ArcReactor extends StatefulWidget {
  const ArcReactor({super.key, required this.phase, required this.onTap});
  final Phase phase;
  final VoidCallback onTap;

  @override
  State<ArcReactor> createState() => _ArcReactorState();
}

class _ArcReactorState extends State<ArcReactor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.phase != Phase.idle;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.mediumImpact();
        widget.onTap();
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final side = math.min(box.maxWidth, box.maxHeight);
          return AnimatedBuilder(
            animation: _anim,
            builder: (context, _) {
              final t = _anim.value;
              final pulse = (math.sin(t * math.pi * 2 * 8) + 1) / 2;
              return Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: Size.square(side),
                    painter: _ReactorPainter(
                      t: t,
                      pulse: pulse,
                      intensity: active ? 1.0 : 0.45,
                    ),
                  ),
                  Icon(
                    Icons.bolt,
                    size: side * 0.24,
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: kOrange, blurRadius: 24),
                      Shadow(color: kGold, blurRadius: 8),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _ReactorPainter extends CustomPainter {
  _ReactorPainter({
    required this.t,
    required this.pulse,
    required this.intensity,
  });

  final double t;
  final double pulse;
  final double intensity;

  static const double _twoPi = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // Ambient glow
    canvas.drawCircle(
      c,
      r * 0.88,
      Paint()
        ..color = kOrange.withValues(
            alpha: ((0.10 + 0.18 * pulse) * intensity + 0.05).clamp(0.0, 1.0))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
    );

    // Outer ring
    canvas.drawCircle(
      c,
      r * 0.96,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = kAmber.withValues(alpha: 0.35 + 0.5 * intensity),
    );

    // Radar sweep
    canvas.drawCircle(
      c,
      r * 0.92,
      Paint()
        ..shader = SweepGradient(
          colors: [
            kOrange.withValues(alpha: 0.0),
            kOrange.withValues(alpha: 0.30 * intensity),
          ],
          transform: GradientRotation(t * _twoPi * 2),
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.92)),
    );

    // HUD tick ring
    final tick = Paint()
      ..strokeWidth = 1.5
      ..color = kAmber.withValues(alpha: 0.25 + 0.4 * intensity);
    for (var i = 0; i < 72; i++) {
      final ang = i * _twoPi / 72 - t * _twoPi * 0.25;
      final dir = Offset(math.cos(ang), math.sin(ang));
      final inner = r * (i % 6 == 0 ? 0.89 : 0.92);
      canvas.drawLine(c + dir * inner, c + dir * (r * 0.955), tick);
    }

    // Orbiting particles
    for (var i = 0; i < 16; i++) {
      final ang = t * _twoPi * (i.isEven ? 1.0 : -0.7) + i * 0.9;
      final rad = r * (0.30 + 0.60 * ((i * 37) % 10) / 10);
      canvas.drawCircle(
        c + Offset(math.cos(ang), math.sin(ang)) * rad,
        2.0 + (i % 3),
        Paint()
          ..color = kGold.withValues(alpha: 0.35 + 0.5 * pulse * intensity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }

    _arcs(canvas, c, r * 0.84, 12, 0.55, t * _twoPi, 8, kOrange, true);
    _arcs(canvas, c, r * 0.68, 6, 0.7, -t * _twoPi * 1.5, 5, kGold, true);
    _arcs(canvas, c, r * 0.55, 24, 0.4, t * _twoPi * 2, 3, kAmber, false);

    // Core
    final coreRect = Rect.fromCircle(center: c, radius: r * 0.40);
    canvas.drawCircle(
      c,
      r * 0.40,
      Paint()
        ..shader = RadialGradient(
          colors: [
            kGold.withValues(alpha: 0.95),
            kOrange.withValues(alpha: 0.55 + 0.3 * pulse * intensity),
            kOrange.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(coreRect),
    );
    canvas.drawCircle(
      c,
      r * 0.40,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = kGold.withValues(alpha: 0.8),
    );
  }

  void _arcs(Canvas canvas, Offset c, double radius, int count, double fill,
      double rotation, double width, Color color, bool glow) {
    final step = _twoPi / count;
    final rect = Rect.fromCircle(center: c, radius: radius);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.35 + 0.6 * intensity);
    final blur = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width + 4
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.5 * intensity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    for (var i = 0; i < count; i++) {
      final start = rotation + i * step;
      if (glow) canvas.drawArc(rect, start, step * fill, false, blur);
      canvas.drawArc(rect, start, step * fill, false, base);
    }
  }

  @override
  bool shouldRepaint(covariant _ReactorPainter old) =>
      old.t != t || old.pulse != pulse || old.intensity != intensity;
}


// ─────────────────────────────────────────────────────────────
// Assistant name + voice controls (inside Settings)
// ─────────────────────────────────────────────────────────────
class _NameAndVoice extends StatefulWidget {
  const _NameAndVoice();
  @override
  State<_NameAndVoice> createState() => _NameAndVoiceState();
}

class _NameAndVoiceState extends State<_NameAndVoice> {
  late final TextEditingController _name;
  late final TextEditingController _eKey;
  late final TextEditingController _eVoice;
  late String _lang;
  late double _pitch;
  late double _rate;
  String? _voice;
  List<Map<String, String>> _voices = [];

  @override
  void initState() {
    super.initState();
    final c = context.read<AssistantController>();
    _name = TextEditingController(text: c.assistantName);
    _eKey = TextEditingController(text: c.elevenKey);
    _eVoice = TextEditingController(text: c.elevenVoiceId);
    _lang = c.listenLang;
    _pitch = c.voicePitch;
    _rate = c.voiceRate;
    _voice = c.voiceName;
    c.listVoices().then((v) {
      if (mounted) setState(() => _voices = v);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _eKey.dispose();
    _eVoice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.read<AssistantController>();
    final items = _voices
        .map((v) => DropdownMenuItem<String>(
              value: '${v['name']}|${v['locale']}',
              child: Text('${v['name']} (${v['locale']})',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ))
        .toList();
    final selected = items.any((i) => i.value == _voice) ? _voice : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Assistant name',
            labelStyle: TextStyle(color: kAmber),
          ),
          onChanged: (v) => c.saveVoice(name: v),
        ),
        const SizedBox(height: 10),
        const SizedBox(height: 6),
        const Text('ElevenLabs voice (recommended)',
            style: TextStyle(color: kGold, fontSize: 13)),
        TextField(
          controller: _eKey,
          obscureText: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'ElevenLabs API key',
            labelStyle: TextStyle(color: kAmber),
          ),
          onChanged: (v) => c.saveEleven(key: v),
        ),
        TextField(
          controller: _eVoice,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'ElevenLabs Voice ID',
            labelStyle: TextStyle(color: kAmber),
          ),
          onChanged: (v) => c.saveEleven(voiceId: v),
        ),
        const SizedBox(height: 12),
        const Text('Microphone language',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        DropdownButton<String>(
          isExpanded: true,
          dropdownColor: kPanel,
          value: _lang,
          items: const [
            DropdownMenuItem(
                value: 'hi_IN',
                child: Text('Hindi (India)', style: TextStyle(color: Colors.white))),
            DropdownMenuItem(
                value: 'en_IN',
                child: Text('English (India)', style: TextStyle(color: Colors.white))),
            DropdownMenuItem(
                value: '',
                child: Text('Phone default', style: TextStyle(color: Colors.white))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _lang = v);
            c.saveListenLang(v);
          },
        ),
        const SizedBox(height: 10),
        Text('Phone voice (fallback)  ',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        Text('Voice pitch  ${_pitch.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        Slider(
          value: _pitch,
          min: 0.8,
          max: 1.8,
          activeColor: kAmber,
          onChanged: (v) => setState(() => _pitch = v),
          onChangeEnd: (v) => c.saveVoice(pitch: v),
        ),
        Text('Speech speed  ${_rate.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        Slider(
          value: _rate,
          min: 0.3,
          max: 0.8,
          activeColor: kAmber,
          onChanged: (v) => setState(() => _rate = v),
          onChangeEnd: (v) => c.saveVoice(rate: v),
        ),
        if (items.isNotEmpty)
          DropdownButton<String>(
            isExpanded: true,
            dropdownColor: kPanel,
            value: selected,
            hint: const Text('Choose a voice',
                style: TextStyle(color: Colors.white54)),
            items: items,
            onChanged: (v) {
              setState(() => _voice = v);
              c.saveVoice(voice: v);
            },
          ),
        TextButton.icon(
          onPressed: c.previewVoice,
          icon: const Icon(Icons.volume_up, color: kGold),
          label: const Text('Preview voice', style: TextStyle(color: kGold)),
        ),
      ],
    );
  }
}
