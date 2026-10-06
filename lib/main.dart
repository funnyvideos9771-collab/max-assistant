import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
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
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MAX JARVIS ASSISTANT',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF020406),
        colorScheme: const ColorScheme.dark(primary: Colors.amberAccent),
      ),
      home: const HomeScreen(),
    );
  }
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

  // ---- state flags ----
  bool _speechReady = false;
  bool _isListening = false;
  bool _isLoading = false;
  bool _standbyMode = false;
  bool _commandMode = false; 
  bool _speaking = false;
  bool _processing = false;
  bool _starting = false;
  int _speakGen = 0;

  String _userSpeech = "";
  String _aiResponse = "JARVIS CORE ONLINE. Ready for your command, Boss.";
  String _role = "Boss";
  String _provider = "auto"; 
  String _geminiKey = "";
  String _groqKey = "";
  String _aiLabel = "";

  String? _geminiModelCache;
  String? _groqModelCache;
  List<Contact>? _contactsCache;

  final List<Map<String, String>> _history = [];

  static const _wakeWords = [
    'hello power', 'hello pawar', 'hello powar', 'hallo power',
    'helo power', 'hey power', 'hello paawar', 'hello pavar',
  ];

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _initTts();
    _loadSettings();
    _requestPermissions();
  }

  @override
  void dispose() {
    _anim.dispose();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.camera,
      Permission.phone,
      Permission.contacts,
    ].request();
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
      _speechReady = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: _onSpeechError,
      );
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
    });
  }

  Future<void> _saveSettings(String role, String provider, String gemini, String groq) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('user_role', role);
    await p.setString('provider', provider);
    await p.setString('gemini_api_key', gemini.trim());
    await p.setString('groq_api_key', groq.trim());
    setState(() {
      _role = role;
      _provider = provider;
      _geminiKey = gemini.trim();
      _groqKey = groq.trim();
      _geminiModelCache = null;
      _groqModelCache = null;
    });
    await _testKeys();
  }

  void _onSpeechStatus(String s) {
    if (s == 'done' || s == 'notListening') {
      if (mounted) setState(() => _isListening = false);
      _scheduleStandbyRestart(const Duration(milliseconds: 400));
    }
  }

  void _onSpeechError(dynamic e) {
    if (mounted) setState(() => _isListening = false);
    _scheduleStandbyRestart(const Duration(milliseconds: 1500));
  }

  void _scheduleStandbyRestart(Duration d) {
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
      _say("Mic ya speech permission nahi mili, Boss.");
      return;
    }
    if (_speech.isListening) return;
    _starting = true;
    _commandMode = command;
    if (command && mounted) {
      setState(() {
        _userSpeech = "";
        _aiResponse = "Sun raha hoon...";
      });
    }
    try {
      await _speech.listen(
        onResult: _onSpeechResult,
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

  void _onSpeechResult(stt.SpeechRecognitionResult r) {
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
      final idx = lower.indexOf(w);
      if (idx >= 0) {
        final rest = lower.substring(idx + w.length).trim();
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
      _say("Standby mode on ho gaya, $_role. 'Hello Power' bolkar bulaiye.");
    } else {
      _commandMode = false;
      _speech.stop();
      setState(() => _isListening = false);
      _say("Standby mode off kar diya.");
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

  String _clean(String t) => t.replaceAll(RegExp(r'[*#`_~]'), '');

  Future<void> _say(String text, {bool listenNext = false}) async {
    final gen = ++_speakGen;
    if (mounted) {
      setState(() {
        _isLoading = false;
        _aiResponse = text;
      });
    }
    _speaking = true;
    try {
      if (_speech.isListening) await _speech.stop();
      await _tts.stop();
      await _tts.speak(_clean(text));
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

  Future<void> _process(String cmd) async {
    if (_processing) return;
    _processing = true;
    try {
      final handled = await _nativeCommands(cmd);
      if (!handled) await _aiReply(cmd);
    } catch (_) {
      await _say("Kuch gadbad ho gayi, $_role. Dobara try karein.");
    } finally {
      _processing = false;
      _scheduleStandbyRestart(const Duration(milliseconds: 600));
    }
  }

  bool _has(String t, List<String> words) => words.any((w) => t.contains(w));

  Future<bool> _open(String url, {bool external = true}) async {
    try {
      return await launchUrl(Uri.parse(url),
          mode: external ? LaunchMode.externalApplication : LaunchMode.platformDefault);
    } catch (_) {
      return false;
    }
  }

  Future<List<Contact>> _contacts({bool refresh = false}) async {
    if (!refresh && _contactsCache != null) return _contactsCache!;
    if (!await FlutterContacts.requestPermission(readonly: true)) return [];
    _contactsCache = await FlutterContacts.getContacts(withProperties: true);
    return _contactsCache!;
  }

  String _onlyDigits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  Future<bool> _nativeCommands(String command) async {
    final text = command.toLowerCase().trim();
    final digits = _onlyDigits(text);

    if (_has(text, ['chup', 'stop speaking', 'shut up', 'bas karo'])) {
      await _tts.stop();
      return true;
    }

    if (_has(text, ['history clear', 'chat clear', 'memory clear', 'sab bhool jao'])) {
      _history.clear();
      _say("Purani baatein bhula di, $_role.");
      return true;
    }

    if (_has(text, ['time kya', 'kitne baje', 'samay kya', 'what time', 'current time'])) {
      final n = DateTime.now();
      final h = n.hour % 12 == 0 ? 12 : n.hour % 12;
      final m = n.minute.toString().padLeft(2, '0');
      _say("Abhi $h:$m ${n.hour >= 12 ? 'PM' : 'AM'} ho raha hai, $_role.");
      return true;
    }
    
    if (_has(text, ['aaj ki date', 'aaj ki tarikh', 'today date', "today's date", 'aaj kaun sa din'])) {
      final n = DateTime.now();
      const days = ['Somvar', 'Mangalvar', 'Budhvar', 'Guruvar', 'Shukravar', 'Shanivar', 'Ravivar'];
      _say("Aaj ${days[n.weekday - 1]} hai, ${n.day}/${n.month}/${n.year}, $_role.");
      return true;
    }

    if (digits.length >= 6 && _has(text, ['kiska', 'whose', 'detail', 'truecaller', 'who is', 'pata', 'check'])) {
      await _lookupNumber(digits);
      return true;
    }

    if (_has(text, ['call', 'phone', 'lagao', 'dial'])) {
      if (digits.length >= 6) {
        _say("$digits par call laga raha hoon, $_role.");
        await _open('tel:$digits', external: false);
        return true;
      }
      const filler = {
        'call', 'phone', 'lagao', 'laga', 'karo', 'kar', 'do', 'dial', 'ko', 'ka',
        'number', 'please', 'plz', 'to', 'mummy', 'ji'
      };
      final raw = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      var name = raw.where((w) => !filler.contains(w)).join(' ').trim();
      if (name.isEmpty) name = raw.where((w) => !{'call', 'phone', 'lagao', 'laga', 'karo', 'kar', 'do', 'dial', 'ko', 'ka', 'number'}.contains(w)).join(' ').trim();
      if (name.isEmpty) {
        _say("Kisko call karna hai, $_role?", listenNext: true);
        return true;
      }
      final list = await _contacts();
      Contact? found;
      for (final c in list) {
        if (c.displayName.toLowerCase().contains(name) && c.phones.isNotEmpty) {
          found = c;
          break;
        }
      }
      if (found == null) {
        _say("'$name' naam ka contact nahi mila, $_role.");
      } else {
        _say("${found.displayName} ko call laga raha hoon, $_role.");
        await _open('tel:${found.phones.first.number}', external: false);
      }
      return true;
    }

    if (text.contains('whatsapp')) {
      _say("WhatsApp open kar raha hoon, $_role.");
      if (!await _open('whatsapp://send', external: false)) {
        await _open('https://wa.me/');
      }
      return true;
    }

    if (_has(text, ['flashlight', 'flash light', 'torch', 'tourch'])) {
      final off = _has(text, ['off', 'band', 'bujha', 'bandh']);
      try {
        if (off) {
          await TorchLight.disableTorch();
          _say("Flashlight band kar di, $_role.");
        } else {
          await TorchLight.enableTorch();
          _say("Flashlight chalu kar di, $_role.");
        }
      } catch (_) {
        _say("Flashlight abhi use nahi ho pa rahi, $_role.");
      }
      return true;
    }

    if (_has(text, ['youtube', 'gana', 'gaana', 'song', 'chalisa', 'bhajan']) ||
        (text.contains('play') && !text.contains('display')) ||
        text.contains('chalao')) {
      final q = _stripWords(text, [
        'youtube', 'gana', 'gaana', 'song', 'play', 'chalao', 'par', 'on', 'search', 'karo', 'kar', 'do', 'mujhe', 'sunao'
      ]);
      _say(q.isEmpty ? "YouTube open kar raha hoon, $_role." : "YouTube par '$q' chala raha hoon, $_role.");
      await _open(q.isEmpty
          ? 'https://www.youtube.com'
          : 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}');
      return true;
    }

    return false;
  }

  String _stripWords(String text, List<String> remove) {
    final set = remove.toSet();
    return text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !set.contains(w)).join(' ').trim();
  }

  Future<void> _lookupNumber(String digits) async {
    final last = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    _say("Number check kar raha hoon, $_role...");
    final list = await _contacts(refresh: true);
    Contact? match;
    for (final c in list) {
      for (final p in c.phones) {
        if (_onlyDigits(p.number).endsWith(last)) {
          match = c;
          break;
        }
      }
      if (match != null) break;
    }
    if (match != null) {
      _say("$_role, yeh number ${match.displayName} ka hai.");
      return;
    }
    _say("Contacts mein nahi mila, Truecaller par search khol raha hoon, $_role.");
    await _open('https://www.truecaller.com/search/in/$last');
  }

  String get _systemPrompt =>
      "You are Jarvis (Max), a loyal, human-like personal AI assistant created for Sonu and Junu, model name Jivani. "
      "Address the current user respectfully as '$_role'. Reply in natural conversational Hinglish. "
      "Your answers are spoken aloud, so keep them crisp (max 3-4 sentences), polite and direct, with no markdown.";

  Future<void> _aiReply(String prompt) async {
    if (_geminiKey.isEmpty && _groqKey.isEmpty) {
      await _say("Pehle settings mein Gemini ya Groq API key daaliye, $_role.");
      return;
    }
    if (mounted) {
      setState(() {
        _isLoading = true;
        _aiResponse = "Soch raha hoon...";
      });
    }
    _history.add({'role': 'user', 'content': prompt});
    while (_history.length > 12) {
      _history.removeAt(0);
    }
    while (_history.isNotEmpty && _history.first['role'] != 'user') {
      _history.removeAt(0);
    }

    try {
      final ans = await _askAi();
      _history.add({'role': 'assistant', 'content': ans});
      await _say(ans);
    } on AiException catch (e) {
      _history.removeLast();
      await _say(e.message);
    } catch (_) {
      _history.removeLast();
      await _say("Network error aa gaya hai, $_role.");
    }
  }

  Future<String> _askAi() async {
    final order = <String>[];
    final hasG = _geminiKey.isNotEmpty;
    final hasQ = _groqKey.isNotEmpty;
    if (_provider == 'groq') {
      if (hasQ) order.add('groq');
      if (hasG) order.add('gemini');
    } else {
      if (hasG) order.add('gemini');
      if (hasQ) order.add('groq');
    }
    String lastErr = "API key nahi mili.";
    for (final p in order) {
      try {
        final a = p == 'gemini' ? await _askGemini(_history) : await _askGroq(_history);
        return a;
      } on AiException catch (e) {
        lastErr = e.message;
      } catch (_) {
        lastErr = "${p == 'gemini' ? 'Gemini' : 'Groq'}: network error.";
      }
    }
    throw AiException(lastErr);
  }

  String _friendly(String who, int code, String body) {
    if (code == 401 || code == 403 || body.contains('API key not valid')) {
      return "$who API key galat hai ya access nahi hai (code $code).";
    }
    if (code == 429) return "$who ki limit khatam ho gayi, thodi der baad try karein.";
    final short = body.length > 140 ? body.substring(0, 140) : body;
    return "$who error $code: $short";
  }

  Future<String> _groqModel({bool refresh = false}) async {
    if (!refresh && _groqModelCache != null) return _groqModelCache!;
    try {
      final res = await http
          .get(Uri.parse('https://api.groq.com/openai/v1/models'),
              headers: {'Authorization': 'Bearer $_groqKey'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final ids = (jsonDecode(res.body)['data'] as List).map((e) => e['id'].toString()).toList();
        for (final p in ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant']) {
          if (ids.contains(p)) return _groqModelCache = p;
        }
        const bad = ['whisper', 'guard', 'tts', 'playai', 'orpheus', 'safeguard', 'embed'];
        final ok = ids.where((i) => !bad.any(i.contains)).toList();
        if (ok.isNotEmpty) return _groqModelCache = ok.first;
      }
    } catch (_) {}
    return _groqModelCache = 'llama-3.1-8b-instant';
  }

  Future<String> _askGroq(List<Map<String, String>> hist) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final model = await _groqModel(refresh: attempt == 1);
      final res = await http
          .post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_groqKey'},
            body: jsonEncode({
              'model': model,
              'temperature': 0.7,
              'messages': [
                {'role': 'system', 'content': _systemPrompt},
                ...hist,
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final t = jsonDecode(res.body)['choices'][0]['message']['content'].toString().trim();
        _setLabel('Groq', model);
        return t;
      }
      final b = res.body;
      if (attempt == 0 &&
          (res.statusCode == 404 || b.contains('model_not_found') || b.contains('decommissioned'))) {
        continue;
      }
      throw AiException(_friendly('Groq', res.statusCode, b));
    }
    throw AiException("Groq: koi chalne wala model nahi mila.");
  }

  Future<String> _geminiModel({bool refresh = false}) async {
    if (!refresh && _geminiModelCache != null) return _geminiModelCache!;
    try {
      final res = await http
          .get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200'),
              headers: {'x-goog-api-key': _geminiKey})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final models = (jsonDecode(res.body)['models'] as List)
            .where((m) => (m['supportedGenerationMethods'] as List?)?.contains('generateContent') ?? false)
            .map((m) => m['name'].toString().replaceFirst('models/', ''))
            .toList();
        if (models.contains('gemini-flash-latest')) return _geminiModelCache = 'gemini-flash-latest';
        const bad = ['image', 'tts', 'embed', 'live', 'audio', 'exp', 'thinking', 'lite', 'preview', 'robotics', 'computer', '8b'];
        final flash = models.where((n) => n.startsWith('gemini') && n.contains('flash') && !bad.any(n.contains)).toList()
          ..sort((a, b) => b.compareTo(a));
        if (flash.isNotEmpty) return _geminiModelCache = flash.first;
        final any = models.where((n) => n.startsWith('gemini') && !bad.any(n.contains)).toList();
        if (any.isNotEmpty) return _geminiModelCache = any.first;
      }
    } catch (_) {}
    return _geminiModelCache = 'gemini-flash-latest';
  }

  Future<String> _askGemini(List<Map<String, String>> hist) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final model = await _geminiModel(refresh: attempt == 1);
      final res = await http
          .post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
            headers: {'Content-Type': 'application/json', 'x-goog-api-key': _geminiKey},
            body: jsonEncode({
              'systemInstruction': {
                'parts': [
                  {'text': _systemPrompt}
                ]
              },
              'contents': hist
                  .map((m) => {
                        'role': m['role'] == 'assistant' ? 'model' : 'user',
                        'parts': [
                          {'text': m['content']}
                        ]
                      })
                  .toList(),
              'generationConfig': {'temperature': 0.7},
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final parts = data['candidates']?[0]?['content']?['parts'] as List?;
        final t = parts?.map((p) => p['text'] ?? '').join().toString().trim() ?? '';
        if (t.isEmpty) throw AiException("Gemini ne khaali jawab diya, dobara poochiye $_role.");
        _setLabel('Gemini', model);
        return t;
      }
      if (attempt == 0 && (res.statusCode == 404 || res.body.contains('not found'))) continue;
      throw AiException(_friendly('Gemini', res.statusCode, res.body));
    }
    throw AiException("Gemini: koi chalne wala model nahi mila.");
  }

  void _setLabel(String provider, String model) {
    if (mounted) setState(() => _aiLabel = '$provider • $model');
  }

  Future<void> _testKeys() async {
    if (mounted) setState(() { _isLoading = true; _aiResponse = "API keys test kar raha hoon..."; });
    final out = <String>[];
    const ping = [{'role': 'user', 'content': 'Say OK'}];
    if (_geminiKey.isNotEmpty) {
      try {
        await _askGemini(ping);
        out.add("Gemini theek chal raha hai");
      } on AiException catch (e) {
        out.add(e.message);
      } catch (_) {
        out.add("Gemini network error");
      }
    }
    if (_groqKey.isNotEmpty) {
      try {
        await _askGroq(ping);
        out.add("Groq theek chal raha hai");
      } on AiException catch (e) {
        out.add(e.message);
      } catch (_) {
        out.add("Groq network error");
      }
    }
    if (out.isEmpty) out.add("Koi API key save nahi hai");
    await _say("${out.join('. ')}, $_role.");
  }

  void _showSettings() {
    String role = _role;
    String provider = _provider;
    final gCtl = TextEditingController(text: _geminiKey);
    final qCtl = TextEditingController(text: _groqKey);

    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.grey),
          filled: true,
          fillColor: const Color(0xFF020406),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.amberAccent)),
        );
    const label = TextStyle(fontSize: 12, color: Colors.amberAccent);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0C1017),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Colors.amberAccent)),
          title: const Text('Jarvis Settings', style: TextStyle(color: Colors.amberAccent)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Active User Profile:', style: label),
                DropdownButton<String>(
                  value: role,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF0C1017),
                  items: const [
                    DropdownMenuItem(value: "Boss", child: Text("Sonu (Boss)")),
                    DropdownMenuItem(value: "Madam", child: Text("Wife (Madam)")),
                    DropdownMenuItem(value: "Mummy ji", child: Text("Mummy (Mummy ji)")),
                    DropdownMenuItem(value: "Aditi", child: Text("Daughter (Aditi)")),
                  ],
                  onChanged: (v) => setD(() => role = v ?? "Boss"),
                ),
                const SizedBox(height: 10),
                const Text('AI Provider:', style: label),
                DropdownButton<String>(
                  value: provider,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF0C1017),
                  items: const [
                    DropdownMenuItem(value: "auto", child: Text("Auto (Gemini → Groq backup)")),
                    DropdownMenuItem(value: "gemini", child: Text("Gemini first")),
                    DropdownMenuItem(value: "groq", child: Text("Groq first")),
                  ],
                  onChanged: (v) => setD(() => provider = v ?? "auto"),
                ),
                const SizedBox(height: 10),
                const Text('Gemini API Key (AIza...):', style: label),
                const SizedBox(height: 6),
                TextField(controller: gCtl, obscureText: true, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: deco('Gemini key (optional)')),
                const SizedBox(height: 14),
                const Text('Groq API Key (gsk_...):', style: label),
                const SizedBox(height: 6),
                TextField(controller: qCtl, obscureText: true, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: deco('Groq key (optional)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent, foregroundColor: Colors.black),
              onPressed: () {
                Navigator.pop(ctx);
                _saveSettings(role, provider, gCtl.text, qCtl.text);
              },
              child: const Text('Save & Test'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('JARVIS ASSISTANT ($_role)',
            style: const TextStyle(color: Colors.amberAccent, letterSpacing: 1.5, fontSize: 15)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.settings, color: Colors.amberAccent), onPressed: _showSettings),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Standby Wake Word ('Hello Power'): ",
                      style: TextStyle(color: Colors.amberAccent, fontSize: 12)),
                  Switch(
                    value: _standbyMode,
                    activeColor: Colors.amberAccent,
                    onChanged: (_) => _toggleStandby(),
                  ),
                ],
              ),
              if (_userSpeech.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amberAccent.withOpacity(0.4)),
                  ),
                  child: Text('Command: "$_userSpeech"',
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 14),
                      textAlign: TextAlign.center),
                ),
              const Spacer(),
              AnimatedBuilder(
                animation: _anim,
                builder: (context, child) => Transform.rotate(
                  angle: _anim.value * 2 * math.pi,
                  child: child,
                ),
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [
                      Colors.amberAccent.withOpacity(0.0),
                      Colors.deepOrangeAccent.withOpacity(0.6),
                      Colors.amber.withOpacity(0.9),
                      Colors.transparent,
                    ]),
                    boxShadow: [
                      BoxShadow(color: Colors.deepOrange.withOpacity(_isListening ? 0.8 : 0.5), blurRadius: 40, spreadRadius: 8),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.amberAccent, width: 2),
                        color: const Color(0xFF060402),
                      ),
                      child: Center(
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(colors: [Colors.amberAccent, Colors.deepOrange]),
                            boxShadow: [
                              BoxShadow(color: Colors.amberAccent.withOpacity(0.8), blurRadius: 20, spreadRadius: 5),
                            ],
                          ),
                          child: const Icon(Icons.bolt, size: 50, color: Colors.black),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_isLoading)
                const CircularProgressIndicator(color: Colors.amberAccent)
              else
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(_aiResponse,
                        style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                        textAlign: TextAlign.center),
                  ),
                ),
              if (_aiLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('AI: $_aiLabel', style: const TextStyle(color: Colors.white24, fontSize: 10)),
                ),
              const Spacer(),
              GestureDetector(
                onTap: _onMicTap,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [Colors.amberAccent, Colors.deepOrange]),
                    boxShadow: [
                      BoxShadow(color: Colors.amberAccent.withOpacity(0.6), blurRadius: 20, spreadRadius: 3),
                    ],
                  ),
                  child: Icon(_isListening ? Icons.graphic_eq : Icons.mic, color: Colors.black, size: 38),
                ),
              ),
              const SizedBox(height: 10),
              const Text("Tap arc reactor to give command", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
