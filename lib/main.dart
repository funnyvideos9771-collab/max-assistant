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

  String? _geminiModelCache, _groqModelCache;
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

  // ---------------------------------------------------------------- setup
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
      _geminiModelCache = null;
      _groqModelCache = null;
    });
    await _testKeys();
  }

  // ------------------------------------------------------------ listening
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

  // ---------------------------------------------------------------- speak
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

  // ----------------------------------------------------------- agent core
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

  String get _systemPrompt {
    final n = DateTime.now();
    return """You are Jarvis (Max), a loyal, smart personal AI AGENT living inside the user's Android phone. Created for Sonu and Junu, model name Jivani. Address the current user as '$_role'. Current date/time: ${n.toIso8601String()} (India, IST).
Speak natural Hinglish. Your 'say' is spoken aloud: max 3 short sentences, no markdown.
Known facts about the user (long-term memory): ${_memory.isEmpty ? 'none' : _memory.join('; ')}

You can use TOOLS to act on the phone. Reply with ONLY one JSON object, nothing else:
{"action":"<tool or none>","args":{...},"say":"<what to speak to the user>"}
Use "none" for normal conversation or when you need to ask a missing detail.
For info tools (marked INFO) you get a TOOL_RESULT back; then reply again with the final answer using action "none".
Never invent phone numbers. Names are resolved from the contacts automatically.

TOOLS:
call {to}  - dial a contact name or number
sms {to, text} - open SMS compose with the text
whatsapp {to, text} - open WhatsApp chat (to optional, text optional)
open_app {name} - open any installed app by name
alarm {hour(0-23), minute, label} - set an alarm
timer {seconds, label} - start a timer
flashlight {state:"on"|"off"}
youtube {query} - search/play on YouTube
shop {platform:"flipkart"|"amazon"|"meesho", query}
maps {query} - search/navigate in Google Maps
google {query} - open Google search in browser
open_url {url}
save_note {text} - save a note inside the app
remember {fact} - save a lasting fact about the user
forget_memory {} - clear lasting memory
read_notes {} INFO - list saved notes
weather {city} INFO - current weather (WMO weather_code included)
web_search {query} INFO - latest facts from the web
now {} INFO - exact current date and time
lookup_number {number} INFO - who owns this number (contacts, else Truecaller)""";
  }

  Map<String, dynamic>? _parse(String raw) {
    final s = raw.indexOf('{'), e = raw.lastIndexOf('}');
    if (s < 0 || e <= s) return null;
    try {
      final m = jsonDecode(raw.substring(s, e + 1));
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _agent(String text) async {
    if (_geminiKey.isEmpty && _groqKey.isEmpty) {
      await _say("Pehle settings mein Gemini ya Groq API key daaliye, $_role.");
      return;
    }
    if (mounted) setState(() { _isLoading = true; _aiResponse = "Soch raha hoon..."; _actionLog = ""; });
    final msgs = <Map<String, String>>[..._history, {'role': 'user', 'content': text}];
    String finalSay = "";
    String lastResult = "";
    try {
      for (var step = 0; step < 4; step++) {
        final raw = await _llm(msgs);
        final j = _parse(raw);
        if (j == null) {
          finalSay = raw.trim();
          break;
        }
        final action = (j['action'] ?? 'none').toString();
        final say = (j['say'] ?? '').toString().trim();
        final args = j['args'] is Map ? Map<String, dynamic>.from(j['args'] as Map) : <String, dynamic>{};
        if (action == 'none' || action.isEmpty) {
          finalSay = say;
          break;
        }
        if (mounted) setState(() => _actionLog = "⚙ $action ${jsonEncode(args)}");
        lastResult = await _runTool(action, args);
        if (_infoTools.contains(action)) {
          msgs.add({'role': 'assistant', 'content': raw});
          msgs.add({'role': 'user', 'content': 'TOOL_RESULT[$action]: $lastResult'});
          continue;
        }
        finalSay = lastResult.startsWith('Failed') ? lastResult : (say.isNotEmpty ? say : lastResult);
        break;
      }
      if (finalSay.isEmpty) finalSay = lastResult.isNotEmpty ? lastResult : "Kaam ho gaya, $_role.";
      _history.add({'role': 'user', 'content': text});
      _history.add({'role': 'assistant', 'content': finalSay});
      while (_history.length > 10) {
        _history.removeAt(0);
      }
      while (_history.isNotEmpty && _history.first['role'] != 'user') {
        _history.removeAt(0);
      }
      await _say(finalSay);
    } on AiException catch (e) {
      await _say(e.message);
    } catch (_) {
      await _say("Network error aa gaya hai, $_role.");
    }
  }

  // ---------------------------------------------------------------- tools
  String _s(dynamic v) => (v ?? '').toString().trim();

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

  String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  Future<String?> _resolvePhone(String q) async {
    final d = q.replaceAll(RegExp(r'[^0-9+]'), '');
    if (_digits(d).length >= 6) return d;
    final name = q.toLowerCase().trim();
    if (name.isEmpty) return null;
    final list = await _contacts();
    Contact? hit;
    for (final c in list) {
      if (c.phones.isNotEmpty && c.displayName.toLowerCase() == name) { hit = c; break; }
    }
    hit ??= list.cast<Contact?>().firstWhere(
        (c) => c!.phones.isNotEmpty && c.displayName.toLowerCase().contains(name),
        orElse: () => null);
    return hit?.phones.first.number;
  }

  Future<String> _runTool(String tool, Map<String, dynamic> a) async {
    try {
      switch (tool) {
        case 'call':
          final n = await _resolvePhone(_s(a['to']));
          if (n == null) return "Failed: '${_s(a['to'])}' contacts mein nahi mila, $_role.";
          await _open('tel:$n', external: false);
          return "Call laga raha hoon.";

        case 'sms':
          final n = await _resolvePhone(_s(a['to']));
          if (n == null) return "Failed: '${_s(a['to'])}' ka number nahi mila.";
          await _open('sms:$n?body=${Uri.encodeComponent(_s(a['text']))}', external: false);
          return "SMS ready hai, bas send dabaiye.";

        case 'whatsapp':
          final to = _s(a['to']);
          final text = _s(a['text']);
          String? n = to.isEmpty ? null : await _resolvePhone(to);
          if (to.isNotEmpty && n == null) return "Failed: '$to' ka number nahi mila.";
          var url = 'https://wa.me/';
          if (n != null) {
            var d = _digits(n);
            if (d.length == 10) d = '91$d';
            url += d;
          }
          if (text.isNotEmpty) url += '?text=${Uri.encodeComponent(text)}';
          await _open(url);
          return "WhatsApp khol diya.";

        case 'open_app':
          final q = _s(a['name']).toLowerCase();
          _appsCache ??= await InstalledApps.getInstalledApps(false, false);
          dynamic hit;
          for (final app in _appsCache!) {
            if (app.name.toString().toLowerCase() == q) { hit = app; break; }
          }
          hit ??= _appsCache!.cast<dynamic>().firstWhere(
              (app) => app.name.toString().toLowerCase().contains(q),
              orElse: () => null);
          if (hit == null) return "Failed: '$q' naam ki app nahi mili.";
          await InstalledApps.startApp(hit.packageName.toString());
          return "${hit.name} khol di.";

        case 'alarm':
          final h = int.tryParse(_s(a['hour']));
          final m = int.tryParse(_s(a['minute'])) ?? 0;
          if (h == null) return "Failed: alarm ka time samajh nahi aaya.";
          await AndroidIntent(action: 'android.intent.action.SET_ALARM', arguments: {
            'android.intent.extra.alarm.HOUR': h,
            'android.intent.extra.alarm.MINUTES': m,
            'android.intent.extra.alarm.MESSAGE': _s(a['label']).isEmpty ? 'Jarvis' : _s(a['label']),
            'android.intent.extra.alarm.SKIP_UI': true,
          }).launch();
          return "Alarm ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} par set ho gaya.";

        case 'timer':
          final sec = int.tryParse(_s(a['seconds']));
          if (sec == null) return "Failed: timer ka time samajh nahi aaya.";
          await AndroidIntent(action: 'android.intent.action.SET_TIMER', arguments: {
            'android.intent.extra.alarm.LENGTH': sec,
            'android.intent.extra.alarm.MESSAGE': _s(a['label']).isEmpty ? 'Jarvis' : _s(a['label']),
            'android.intent.extra.alarm.SKIP_UI': true,
          }).launch();
          return "Timer chalu ho gaya.";

        case 'flashlight':
          if (_s(a['state']).toLowerCase() == 'off') {
            await TorchLight.disableTorch();
            return "Flashlight band.";
          }
          await TorchLight.enableTorch();
          return "Flashlight chalu.";

        case 'youtube':
          final q = _s(a['query']);
          await _open(q.isEmpty
              ? 'https://www.youtube.com'
              : 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}');
          return "YouTube khol diya.";

        case 'shop':
          final p = _s(a['platform']).toLowerCase();
          final e = Uri.encodeComponent(_s(a['query']));
          final url = p.contains('meesho')
              ? 'https://www.meesho.com/search?q=$e'
              : p.contains('amazon')
                  ? 'https://www.amazon.in/s?k=$e'
                  : 'https://www.flipkart.com/search?q=$e';
          await _open(url);
          return "Search khol diya.";

        case 'maps':
          await _open('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(_s(a['query']))}');
          return "Maps khol diya.";

        case 'google':
          await _open('https://www.google.com/search?q=${Uri.encodeComponent(_s(a['query']))}');
          return "Google khol diya.";

        case 'open_url':
          var u = _s(a['url']);
          if (!u.startsWith('http')) u = 'https://$u';
          await _open(u);
          return "Link khol diya.";

        case 'save_note':
          _notes.add("${DateTime.now().toString().substring(0, 16)} - ${_s(a['text'])}");
          await _persistLists();
          return "Note save kar liya.";

        case 'read_notes':
          return _notes.isEmpty ? "Koi note nahi hai." : _notes.reversed.take(10).join(' | ');

        case 'remember':
          _memory.add(_s(a['fact']));
          if (_memory.length > 40) _memory.removeAt(0);
          await _persistLists();
          return "Yaad rakh liya.";

        case 'forget_memory':
          _memory.clear();
          await _persistLists();
          return "Sab bhula diya.";

        case 'now':
          return DateTime.now().toString();

        case 'weather':
          return await _weather(_s(a['city']));

        case 'web_search':
          return await _webSearch(_s(a['query']));

        case 'lookup_number':
          final d = _digits(_s(a['number']));
          if (d.length < 6) return "Number valid nahi hai.";
          final last = d.length > 10 ? d.substring(d.length - 10) : d;
          for (final c in await _contacts(refresh: true)) {
            for (final p in c.phones) {
              if (_digits(p.number).endsWith(last)) return "Yeh number ${c.displayName} ka hai.";
            }
          }
          await _open('https://www.truecaller.com/search/in/$last');
          return "Contacts mein nahi mila, Truecaller search khol diya.";

        default:
          return "Failed: '$tool' naam ka tool mere paas nahi hai.";
      }
    } catch (e) {
      return "Failed: $tool nahi chal paya.";
    }
  }

  Future<String> _weather(String city) async {
    if (city.isEmpty) return "City ka naam batayein.";
    final g = await http
        .get(Uri.parse('https://geocoding-api.open-meteo.com/v1/search?count=1&name=${Uri.encodeComponent(city)}'))
        .timeout(const Duration(seconds: 15));
    final res = (jsonDecode(g.body)['results'] as List?) ?? [];
    if (res.isEmpty) return "'$city' city nahi mili.";
    final r = res.first;
    final w = await http
        .get(Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=${r['latitude']}&longitude=${r['longitude']}'
            '&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code&timezone=auto'))
        .timeout(const Duration(seconds: 15));
    final c = jsonDecode(w.body)['current'];
    return "${r['name']}: ${c['temperature_2m']}°C, humidity ${c['relative_humidity_2m']}%, "
        "wind ${c['wind_speed_10m']} km/h, weather_code ${c['weather_code']}";
  }

  Future<String> _webSearch(String q) async {
    if (q.isEmpty) return "Kya search karna hai?";
    if (_geminiKey.isNotEmpty) {
      try {
        final model = await _geminiModel();
        final res = await http
            .post(
              Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
              headers: {'Content-Type': 'application/json', 'x-goog-api-key': _geminiKey},
              body: jsonEncode({
                'contents': [
                  {'role': 'user', 'parts': [{'text': "Answer briefly with latest facts: $q"}]}
                ],
                'tools': [{'google_search': {}}],
              }),
            )
            .timeout(const Duration(seconds: 40));
        if (res.statusCode == 200) {
          final parts = jsonDecode(res.body)['candidates']?[0]?['content']?['parts'] as List?;
          final t = parts?.map((p) => p['text'] ?? '').join().toString().trim() ?? '';
          if (t.isNotEmpty) return t;
        }
      } catch (_) {}
    }
    try {
      final res = await http
          .get(Uri.parse('https://api.duckduckgo.com/?q=${Uri.encodeComponent(q)}&format=json&no_html=1&skip_disambig=1'))
          .timeout(const Duration(seconds: 15));
      final d = jsonDecode(res.body);
      final abs = _s(d['AbstractText']);
      if (abs.isNotEmpty) return abs;
      final rel = (d['RelatedTopics'] as List? ?? []).take(3).map((e) => _s(e['Text'])).where((e) => e.isNotEmpty);
      if (rel.isNotEmpty) return rel.join(' | ');
    } catch (_) {}
    return "Web par is baare mein kuch nahi mila.";
  }

  // ------------------------------------------------------------- LLM layer
  Future<String> _llm(List<Map<String, String>> msgs) async {
    final hasG = _geminiKey.isNotEmpty, hasQ = _groqKey.isNotEmpty;
    final order = <String>[];
    if (_provider == 'groq') {
      if (hasQ) order.add('groq');
      if (hasG) order.add('gemini');
    } else {
      if (hasG) order.add('gemini');
      if (hasQ) order.add('groq');
    }
    String err = "API key nahi mili.";
    for (final p in order) {
      try {
        return p == 'gemini' ? await _askGemini(msgs) : await _askGroq(msgs);
      } on AiException catch (e) {
        err = e.message;
      } catch (_) {
        err = "${p == 'gemini' ? 'Gemini' : 'Groq'}: network error.";
      }
    }
    throw AiException(err);
  }

  String _friendly(String who, int code, String body) {
    if (code == 401 || code == 403 || body.contains('API key not valid')) {
      return "$who API key galat hai ya access nahi hai (code $code).";
    }
    if (code == 429) return "$who ki limit khatam ho gayi, thodi der baad try karein.";
    return "$who error $code: ${body.length > 140 ? body.substring(0, 140) : body}";
  }

  void _label(String p, String m) {
    if (mounted) setState(() => _aiLabel = '$p • $m');
  }

  Future<String> _groqModel({bool refresh = false}) async {
    if (!refresh && _groqModelCache != null) return _groqModelCache!;
    try {
      final res = await http
          .get(Uri.parse('https://api.groq.com/openai/v1/models'), headers: {'Authorization': 'Bearer $_groqKey'})
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

  Future<String> _askGroq(List<Map<String, String>> msgs, {String? system}) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final model = await _groqModel(refresh: attempt == 1);
      final res = await http
          .post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_groqKey'},
            body: jsonEncode({
              'model': model,
              'temperature': 0.4,
              'messages': [
                {'role': 'system', 'content': system ?? _systemPrompt},
                ...msgs,
              ],
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 200) {
        _label('Groq', model);
        return jsonDecode(res.body)['choices'][0]['message']['content'].toString().trim();
      }
      if (attempt == 0 &&
          (res.statusCode == 404 || res.body.contains('model_not_found') || res.body.contains('decommissioned'))) {
        continue;
      }
      throw AiException(_friendly('Groq', res.statusCode, res.body));
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

  Future<String> _askGemini(List<Map<String, String>> msgs, {String? system, bool json = true}) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final model = await _geminiModel(refresh: attempt == 1);
      final res = await http
          .post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
            headers: {'Content-Type': 'application/json', 'x-goog-api-key': _geminiKey},
            body: jsonEncode({
              'systemInstruction': {'parts': [{'text': system ?? _systemPrompt}]},
              'contents': msgs
                  .map((m) => {
                        'role': m['role'] == 'assistant' ? 'model' : 'user',
                        'parts': [{'text': m['content']}]
                      })
                  .toList(),
              'generationConfig': {
                'temperature': 0.4,
                if (json) 'responseMimeType': 'application/json',
              },
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 200) {
        final parts = jsonDecode(res.body)['candidates']?[0]?['content']?['parts'] as List?;
        final t = parts?.map((p) => p['text'] ?? '').join().toString().trim() ?? '';
        if (t.isEmpty) throw AiException("Gemini ne khaali jawab diya, dobara poochiye $_role.");
        _label('Gemini', model);
        return t;
      }
      if (attempt == 0 && (res.statusCode == 404 || res.body.contains('not found'))) continue;
      throw AiException(_friendly('Gemini', res.statusCode, res.body));
    }
    throw AiException("Gemini: koi chalne wala model nahi mila.");
  }

  Future<void> _testKeys() async {
    if (mounted) setState(() { _isLoading = true; _aiResponse = "API keys test kar raha hoon..."; });
    final out = <String>[];
    const ping = [{'role': 'user', 'content': 'Say OK'}];
    const sys = 'Reply with OK.';
    if (_geminiKey.isNotEmpty) {
      try {
        await _askGemini(ping, system: sys, json: false);
        out.add("Gemini theek chal raha hai");
      } on AiException catch (e) {
        out.add(e.message);
      } catch (_) {
        out.add("Gemini network error");
      }
    }
    if (_groqKey.isNotEmpty) {
      try {
        await _askGroq(ping, system: sys);
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

  // -------------------------------------------------------------- dialogs
  void _showTypeDialog() {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0C1017),
        title: const Text('Command type karein', style: TextStyle(color: Colors.amberAccent, fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'jaise: mummy ko call karo'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(ctx);
              if (c.text.trim().isNotEmpty) {
                setState(() => _userSpeech = c.text.trim());
                _process(c.text.trim());
              }
            },
            child: const Text('Bhejo'),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    String role = _role, provider = _provider;
    final gCtl = TextEditingController(text: _geminiKey);
    final qCtl = TextEditingController(text: _groqKey);
    InputDecoration deco(String h) => InputDecoration(
          hintText: h,
          hintStyle: const TextStyle(color: Colors.grey),
          filled: true,
          fillColor: const Color(0xFF020406),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.amberAccent)),
        );
    const lab = TextStyle(fontSize: 12, color: Colors.amberAccent);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0C1017),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Colors.amberAccent)),
          title: const Text('Jarvis Settings', style: TextStyle(color: Colors.amberAccent)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Active User Profile:', style: lab),
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
                const SizedBox(height: 8),
                const Text('AI Provider:', style: lab),
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
                const SizedBox(height: 8),
                const Text('Gemini API Key (AIza...):', style: lab),
                const SizedBox(height: 6),
                TextField(controller: gCtl, obscureText: true, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: deco('Gemini key')),
                const SizedBox(height: 12),
                const Text('Groq API Key (gsk_...):', style: lab),
                const SizedBox(height: 6),
                TextField(controller: qCtl, obscureText: true, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: deco('Groq key')),
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

  // ------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('JARVIS AGENT ($_role)',
            style: const TextStyle(color: Colors.amberAccent, letterSpacing: 1.5, fontSize: 15)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.keyboard, color: Colors.amberAccent), onPressed: _showTypeDialog),
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
                  Switch(value: _standbyMode, activeColor: Colors.amberAccent, onChanged: (_) => _toggleStandby()),
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
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 14), textAlign: TextAlign.center),
                ),
              const Spacer(),
              AnimatedBuilder(
                animation: _anim,
                builder: (context, child) => Transform.rotate(angle: _anim.value * 2 * math.pi, child: child),
                child: Container(
                  width: 200,
                  height: 200,
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
                      width: 135,
                      height: 135,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.amberAccent, width: 2),
                        color: const Color(0xFF060402),
                      ),
                      child: Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(colors: [Colors.amberAccent, Colors.deepOrange]),
                            boxShadow: [BoxShadow(color: Colors.amberAccent.withOpacity(0.8), blurRadius: 20, spreadRadius: 5)],
                          ),
                          child: const Icon(Icons.bolt, size: 46, color: Colors.black),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
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
              if (_actionLog.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_actionLog,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
                      textAlign: TextAlign.center),
                ),
              if (_aiLabel.isNotEmpty)
                Text('AI: $_aiLabel', style: const TextStyle(color: Colors.white24, fontSize: 10)),
              const Spacer(),
              GestureDetector(
                onTap: _onMicTap,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxSpace.circle, // (Note: kept standard layout)
                    gradient: const LinearGradient(colors: [Colors.amberAccent, Colors.deepOrange]),
                    boxShadow: [BoxShadow(color: Colors.amberAccent.withOpacity(0.6), blurRadius: 20, spreadRadius: 3)],
                  ),
                  child: Icon(_isListening ? Icons.graphic_eq : Icons.mic, color: Colors.black, size: 38),
                ),
              ),
              const SizedBox(height: 8),
              const Text("Tap arc reactor to give command", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }
}
