import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart'; // FIX: error yahi missing import tha
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';

const _themes = <String, Color>{
  'Crimson Core': Color(0xFFE5173F),
  'Cyan Pulse': Color(0xFF19E6D4),
  'Neon Matrix': Color(0xFF2BFF4F),
};
const _apps = <String, String>{
  'whatsapp': 'com.whatsapp', 'instagram': 'com.instagram.android', 'youtube': 'com.google.android.youtube',
  'chrome': 'com.android.chrome', 'gmail': 'com.google.android.gm', 'maps': 'com.google.android.apps.maps',
  'facebook': 'com.facebook.katana', 'telegram': 'org.telegram.messenger', 'snapchat': 'com.snapchat.android',
  'phonepe': 'com.phonepe.app', 'paytm': 'net.one97.paytm', 'gpay': 'com.google.android.apps.nbu.paisa.user',
  'flipkart': 'com.flipkart.android', 'amazon': 'in.amazon.mShop.android.shopping', 'meesho': 'com.meesho.supply',
  'truecaller': 'com.truecaller', 'spotify': 'com.spotify.music', 'netflix': 'com.netflix.mediaclient',
  'hotstar': 'in.startv.hotstar', 'calculator': 'com.google.android.calculator',
  'photos': 'com.google.android.apps.photos', 'clock': 'com.google.android.deskclock',
  'contacts': 'com.google.android.contacts', 'messages': 'com.google.android.apps.messaging',
  'phone': 'com.google.android.dialer', 'play store': 'com.android.vending',
};
const _info = <String>{'weather', 'web_search', 'now', 'read_notes', 'lookup_number'};
const _quotes = <String>[
  'The best way to predict the future is to create it.',
  'Small steps every day beat big plans never started.',
  'Focus on progress, not perfection.',
  'Discipline is choosing what you want most over what you want now.',
];

class AiException implements Exception {
  final String message;
  AiException(this.message);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaxApp());
}

class MaxApp extends StatelessWidget {
  const MaxApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'MAX',
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
        home: const Shell(),
      );
}

class OrbPainter extends CustomPainter {
  final double t;
  final Color color;
  final bool active;
  OrbPainter(this.t, this.color, this.active);

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final r = s.width / 2;
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [color.withOpacity(active ? 0.55 : 0.3), Colors.transparent])
              .createShader(Rect.fromCircle(center: c, radius: r)));
    for (int i = 0; i < 3; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(t * 2 * math.pi * (i.isEven ? 1 : -1) * (1 + i * 0.4) + i);
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4 - i * 0.6
        ..color = (i == 1 ? Colors.white : color).withOpacity(0.85 - i * 0.2);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: r * 1.5, height: r * (1.0 + i * 0.22)), p);
      canvas.restore();
    }
    final core = Rect.fromCircle(center: c, radius: r * 0.27);
    canvas.drawCircle(
        c,
        r * 0.27,
        Paint()..shader = RadialGradient(colors: [color.withOpacity(0.95), color.withOpacity(0.5)]).createShader(core));
  }

  @override
  bool shouldRepaint(OrbPainter o) => true;
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final TextEditingController _input = TextEditingController();
  late final AnimationController _anim;

  int _tab = 0, _gen = 0;
  bool _ready = false, _listening = false, _busy = false, _standby = false;
  bool _cmdMode = false, _speaking = false, _starting = false, _teacher = false;
  String _status = '', _action = '';
  String _user = 'Boss', _wake = 'power', _provider = 'auto', _gKey = '', _qKey = '';
  String _themeName = 'Crimson Core', _wall = '';
  String? _gModel, _qModel;
  List<Contact>? _contactsCache;
  List<String> _memory = [], _notes = [];
  List<Map<String, String>> _chat = [];

  Color get _accent => _themes[_themeName] ?? _themes.values.first;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();
    _load().then((_) {
      // Pehli baar app khule aur koi key na ho to key ka dialog dikhao
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _gKey.isEmpty && _qKey.isEmpty) _setKey(true);
      });
    });
    _tts.setLanguage('hi-IN');
    _tts.setSpeechRate(0.5);
    _tts.setPitch(0.95);
    _tts.awaitSpeakCompletion(true);
    [Permission.microphone, Permission.camera, Permission.phone, Permission.contacts].request();
  }

  @override
  void dispose() {
    _anim.dispose();
    _input.dispose();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  // ------------------------------------------------------------ storage
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _user = p.getString('user') ?? 'Boss';
      _wake = p.getString('wake') ?? 'power';
      _provider = p.getString('provider') ?? 'auto';
      _gKey = (p.getString('gkey') ?? '').trim();
      _qKey = (p.getString('qkey') ?? '').trim();
      _themeName = p.getString('theme') ?? 'Crimson Core';
      _wall = p.getString('wall') ?? '';
      _memory = p.getStringList('memory') ?? [];
      _notes = p.getStringList('notes') ?? [];
      _chat = (p.getStringList('chat') ?? [])
          .map((s) => Map<String, String>.from(jsonDecode(s) as Map))
          .toList();
    });
  }

  Future<void> _put(String k, String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(k, v);
  }

  Future<void> _putList(String k, List<String> v) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(k, v);
  }

  Future<void> _saveChat() =>
      _putList('chat', _chat.skip(math.max(0, _chat.length - 100)).map((m) => jsonEncode(m)).toList());

  // ------------------------------------------------------------- speech
  void _onStatus(String s) {
    if (s == 'done' || s == 'notListening') {
      if (mounted) setState(() => _listening = false);
      _restart(const Duration(milliseconds: 400));
    }
  }

  void _onError(dynamic e) {
    if (mounted) setState(() => _listening = false);
    _restart(const Duration(milliseconds: 1500));
  }

  void _restart(Duration d) {
    if (!_standby) return;
    Future.delayed(d, () {
      if (mounted && _standby && !_speech.isListening && !_speaking && !_busy && !_starting) {
        _listen(command: false);
      }
    });
  }

  Future<void> _listen({required bool command}) async {
    if (_starting) return;
    if (!_ready) {
      try {
        _ready = await _speech.initialize(onStatus: _onStatus, onError: _onError);
      } catch (_) {
        _ready = false;
      }
    }
    if (!_ready) {
      _say('Mic ya speech permission nahi mili, $_user.');
      return;
    }
    if (_speech.isListening) return;
    _starting = true;
    _cmdMode = command;
    if (command && mounted) setState(() => _status = 'Sun raha hoon...');
    try {
      await _speech.listen(
        onResult: _onResult,
        localeId: 'en_IN',
        listenFor: Duration(seconds: command ? 20 : 60),
        pauseFor: Duration(seconds: command ? 3 : 4),
        listenOptions: stt.SpeechListenOptions(partialResults: true, cancelOnError: false),
      );
      if (mounted) setState(() => _listening = true);
    } catch (_) {
      if (mounted) setState(() => _listening = false);
    } finally {
      _starting = false;
    }
  }

  String? _afterWake(String l) {
    final w = _wake.toLowerCase().trim();
    if (w.isEmpty) return null;
    for (final p in ['wake up $w', 'hello $w', 'hey $w', w]) {
      final m = RegExp('\\b${RegExp.escape(p)}\\b').firstMatch(l);
      if (m != null) return l.substring(m.end).trim();
    }
    return null;
  }

  // FIX: pehle 'stt.SpeechRecognitionResult' tha, ab seedha SpeechRecognitionResult
  void _onResult(SpeechRecognitionResult r) {
    final w = r.recognizedWords.trim();
    if (mounted) setState(() => _status = w);
    if (!r.finalResult || w.isEmpty) return;
    if (_cmdMode) {
      _cmdMode = false;
      _process(w);
      return;
    }
    final rest = _afterWake(w.toLowerCase());
    if (rest == null) return;
    if (rest.length > 2) {
      _process(rest);
    } else {
      _say('Boliye $_user, main sun raha hoon.', next: true);
    }
  }

  void _toggleStandby() {
    setState(() => _standby = !_standby);
    if (_standby) {
      _say("Standby on ho gaya, $_user. 'Hey $_wake' bolkar bulaiye.");
    } else {
      _cmdMode = false;
      _speech.stop();
      setState(() => _listening = false);
      _say('Standby off kar diya.');
    }
  }

  void _mic() {
    if (_speech.isListening) {
      _cmdMode = false;
      _speech.stop();
    } else {
      _tts.stop();
      _listen(command: true);
    }
  }

  Future<void> _say(String text, {bool next = false}) async {
    final g = ++_gen;
    if (mounted) setState(() => _status = text);
    _speaking = true;
    try {
      if (_speech.isListening) await _speech.stop();
      await _tts.stop();
      await _tts.speak(text.replaceAll(RegExp(r'[*#`_~]'), ''));
    } catch (_) {}
    if (g != _gen) return;
    _speaking = false;
    if (!mounted) return;
    if (next) {
      _listen(command: true);
    } else if (_standby) {
      _listen(command: false);
    }
  }

  // -------------------------------------------------------------- agent
  String get _sys => """You are MAX, a loyal, smart personal AI agent living inside the user's Android phone. The user is called '$_user'. Now: ${DateTime.now().toIso8601String()} (IST).
Reply in natural Hinglish; 'say' is spoken aloud: max 3 short sentences, no markdown.${_teacher ? ' MODE English Teacher: reply in simple English, gently correct the user mistakes and ask one follow-up question.' : ''}
Long-term memory: ${_memory.isEmpty ? 'none' : _memory.join('; ')}
Reply with ONLY one JSON object: {"action":"<tool or none>","args":{},"say":"<speech>"}. Use "none" to chat or to ask for a missing detail. INFO tools return a TOOL_RESULT, then answer with action "none". Never invent phone numbers.
TOOLS: call{to} sms{to,text} whatsapp{to,text} open_app{name,package?} alarm{hour,minute,label} flashlight{state:on|off} youtube{query} maps{query} shop{platform:flipkart|amazon|meesho,query} open_url{url} remember{fact} save_note{text} read_notes{}INFO weather{city}INFO web_search{query}INFO now{}INFO lookup_number{number}INFO""";

  Map<String, dynamic>? _json(String raw) {
    final s = raw.indexOf('{'), e = raw.lastIndexOf('}');
    if (s < 0 || e <= s) return null;
    try {
      final m = jsonDecode(raw.substring(s, e + 1));
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _process(String text, {bool mission = false}) async {
    if (_busy || text.trim().isEmpty) return;
    if (RegExp(r'\b(chup|stop speaking|bas karo)\b').hasMatch(text.toLowerCase())) {
      await _tts.stop();
      return;
    }
    if (_gKey.isEmpty && _qKey.isEmpty) {
      _say('Pehle Settings mein Gemini ya Groq key daaliye, $_user.');
      return;
    }
    setState(() {
      _busy = true;
      _status = '';
      _action = '';
    });
    final msgs = <Map<String, String>>[
      for (final m in _chat.reversed.take(8).toList().reversed) {'role': m['role'] ?? 'user', 'content': m['text'] ?? ''},
      {'role': 'user', 'content': text},
    ];
    while (msgs.length > 1 && msgs.first['role'] != 'user') {
      msgs.removeAt(0);
    }
    String say = '', last = '';
    try {
      for (var i = 0; i < (mission ? 8 : 4); i++) {
        final raw = await _llm(msgs);
        final j = _json(raw);
        if (j == null) {
          say = raw.trim();
          break;
        }
        final act = '${j['action'] ?? 'none'}';
        final s = '${j['say'] ?? ''}'.trim();
        final args = j['args'] is Map ? Map<String, dynamic>.from(j['args'] as Map) : <String, dynamic>{};
        if (s.isNotEmpty) say = s;
        if (act == 'none' || act.isEmpty) break;
        if (mounted) setState(() => _action = '⚙ $act');
        last = await _tool(act, args);
        if (_info.contains(act) || (mission && !last.startsWith('Failed'))) {
          msgs.add({'role': 'assistant', 'content': raw});
          msgs.add({'role': 'user', 'content': 'TOOL_RESULT[$act]: $last. Continue or finish with action none.'});
          continue;
        }
        if (last.startsWith('Failed')) say = last;
        break;
      }
      if (say.isEmpty) say = last.isNotEmpty ? last : 'Kaam ho gaya, $_user.';
      _chat.add({'role': 'user', 'text': text});
      _chat.add({'role': 'assistant', 'text': say});
      _saveChat();
    } on AiException catch (e) {
      say = e.message;
    } catch (_) {
      say = 'Network error aa gaya hai, $_user.';
    }
    if (mounted) setState(() => _busy = false);
    await _say(say);
  }

  // -------------------------------------------------------------- tools
  String _s(dynamic v) => (v ?? '').toString().trim();
  String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  Future<bool> _open(String u, [bool ext = true]) async {
    try {
      return await launchUrl(Uri.parse(u), mode: ext ? LaunchMode.externalApplication : LaunchMode.platformDefault);
    } catch (_) {
      return false;
    }
  }

  Future<List<Contact>> _contacts({bool fresh = false}) async {
    if (!fresh && _contactsCache != null) return _contactsCache!;
    if (!await FlutterContacts.requestPermission(readonly: true)) return [];
    return _contactsCache = await FlutterContacts.getContacts(withProperties: true);
  }

  Future<String?> _phone(String q) async {
    final d = q.replaceAll(RegExp(r'[^0-9+]'), '');
    if (_digits(d).length >= 6) return d;
    final n = q.toLowerCase().trim();
    if (n.isEmpty) return null;
    final list = (await _contacts()).where((c) => c.phones.isNotEmpty).toList();
    for (final c in list) {
      if (c.displayName.toLowerCase() == n) return c.phones.first.number;
    }
    for (final c in list) {
      if (c.displayName.toLowerCase().contains(n)) return c.phones.first.number;
    }
    return null;
  }

  Future<String> _tool(String tool, Map<String, dynamic> a) async {
    try {
      switch (tool) {
        case 'call':
          {
            final n = await _phone(_s(a['to']));
            if (n == null) return "Failed: '${_s(a['to'])}' contacts mein nahi mila, $_user.";
            await _open('tel:$n', false);
            return 'Call laga raha hoon.';
          }
        case 'sms':
          {
            final n = await _phone(_s(a['to']));
            if (n == null) return "Failed: '${_s(a['to'])}' ka number nahi mila.";
            await _open('sms:$n?body=${Uri.encodeComponent(_s(a['text']))}', false);
            return 'SMS ready hai, bas send dabaiye.';
          }
        case 'whatsapp':
          {
            final to = _s(a['to']), text = _s(a['text']);
            final n = to.isEmpty ? null : await _phone(to);
            if (to.isNotEmpty && n == null) return "Failed: '$to' ka number nahi mila.";
            var url = 'https://wa.me/';
            if (n != null) {
              var d = _digits(n);
              if (d.length == 10) d = '91$d';
              url += d;
            }
            if (text.isNotEmpty) url += '?text=${Uri.encodeComponent(text)}';
            await _open(url);
            return 'WhatsApp khol diya.';
          }
        case 'open_app':
          {
            final q = _s(a['name']).toLowerCase();
            if (q.contains('camera')) {
              await const AndroidIntent(action: 'android.media.action.STILL_IMAGE_CAMERA').launch();
              return 'Camera khol diya.';
            }
            if (q.contains('setting')) {
              await const AndroidIntent(action: 'android.settings.SETTINGS').launch();
              return 'Settings khol di.';
            }
            String? pkg = _s(a['package']).isEmpty ? null : _s(a['package']);
            if (pkg == null) {
              for (final e in _apps.entries) {
                if (q.contains(e.key)) {
                  pkg = e.value;
                  break;
                }
              }
            }
            if (pkg == null) {
              await _open('https://play.google.com/store/search?q=${Uri.encodeComponent(q)}&c=apps');
              return 'Yeh app listed nahi hai, Play Store mein search khol diya.';
            }
            try {
              await AndroidIntent(
                action: 'android.intent.action.MAIN',
                category: 'android.intent.category.LAUNCHER',
                package: pkg,
                flags: <int>[0x10000000],
              ).launch();
              return '$q khol diya.';
            } catch (_) {
              await _open('https://play.google.com/store/apps/details?id=$pkg');
              return '$q phone mein nahi mili, Play Store khol diya.';
            }
          }
        case 'alarm':
          {
            final h = int.tryParse(_s(a['hour']));
            final m = int.tryParse(_s(a['minute'])) ?? 0;
            if (h == null) return 'Failed: alarm ka time samajh nahi aaya.';
            await AndroidIntent(action: 'android.intent.action.SET_ALARM', arguments: <String, dynamic>{
              'android.intent.extra.alarm.HOUR': h,
              'android.intent.extra.alarm.MINUTES': m,
              'android.intent.extra.alarm.MESSAGE': _s(a['label']).isEmpty ? 'MAX' : _s(a['label']),
              'android.intent.extra.alarm.SKIP_UI': true,
            }).launch();
            return 'Alarm ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} par set ho gaya.';
          }
        case 'flashlight':
          {
            if (_s(a['state']).toLowerCase() == 'off') {
              await TorchLight.disableTorch();
              return 'Flashlight band.';
            }
            await TorchLight.enableTorch();
            return 'Flashlight chalu.';
          }
        case 'youtube':
          {
            final q = _s(a['query']);
            await _open(q.isEmpty
                ? 'https://www.youtube.com'
                : 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}');
            return 'YouTube khol diya.';
          }
        case 'maps':
          await _open('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(_s(a['query']))}');
          return 'Maps khol diya.';
        case 'shop':
          {
            final p = _s(a['platform']).toLowerCase();
            final e = Uri.encodeComponent(_s(a['query']));
            await _open(p.contains('meesho')
                ? 'https://www.meesho.com/search?q=$e'
                : p.contains('amazon')
                    ? 'https://www.amazon.in/s?k=$e'
                    : 'https://www.flipkart.com/search?q=$e');
            return 'Search khol diya.';
          }
        case 'open_url':
          {
            var u = _s(a['url']);
            if (!u.startsWith('http')) u = 'https://$u';
            await _open(u);
            return 'Link khol diya.';
          }
        case 'remember':
          _memory.add(_s(a['fact']));
          if (_memory.length > 40) _memory.removeAt(0);
          await _putList('memory', _memory);
          return 'Yaad rakh liya.';
        case 'save_note':
          _notes.add('${DateTime.now().toString().substring(0, 16)} - ${_s(a['text'])}');
          await _putList('notes', _notes);
          return 'Note save kar liya.';
        case 'read_notes':
          return _notes.isEmpty ? 'Koi note nahi hai.' : _notes.reversed.take(10).join(' | ');
        case 'now':
          return DateTime.now().toString();
        case 'weather':
          return await _weather(_s(a['city']));
        case 'web_search':
          return await _web(_s(a['query']));
        case 'lookup_number':
          {
            final d = _digits(_s(a['number']));
            if (d.length < 6) return 'Number valid nahi hai.';
            final last = d.length > 10 ? d.substring(d.length - 10) : d;
            for (final c in await _contacts(fresh: true)) {
              for (final p in c.phones) {
                if (_digits(p.number).endsWith(last)) return 'Yeh number ${c.displayName} ka hai.';
              }
            }
            await _open('https://www.truecaller.com/search/in/$last');
            return 'Contacts mein nahi mila, Truecaller search khol diya.';
          }
        default:
          return "Failed: '$tool' tool mere paas nahi hai.";
      }
    } catch (_) {
      return 'Failed: $tool nahi chal paya.';
    }
  }

  Future<String> _weather(String city) async {
    if (city.isEmpty) return 'City ka naam batayein.';
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

  Future<String> _web(String q) async {
    if (q.isEmpty) return 'Kya search karna hai?';
    if (_gKey.isNotEmpty) {
      try {
        final model = await _gemModel();
        final res = await http
            .post(
              Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
              headers: {'Content-Type': 'application/json', 'x-goog-api-key': _gKey},
              body: jsonEncode({
                'contents': [
                  {'role': 'user', 'parts': [{'text': 'Answer briefly with latest facts: $q'}]}
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
    return 'Web par kuch nahi mila.';
  }

  // ---------------------------------------------------------- LLM layer
  Future<String> _llm(List<Map<String, String>> msgs) async {
    final order = <String>[
      if (_provider == 'groq' && _qKey.isNotEmpty) 'groq',
      if (_gKey.isNotEmpty) 'gemini',
      if (_qKey.isNotEmpty && _provider != 'groq') 'groq',
    ];
    String err = 'API key nahi mili.';
    for (final p in order.toSet()) {
      try {
        return p == 'gemini' ? await _gemini(msgs) : await _groq(msgs);
      } on AiException catch (e) {
        err = e.message;
      } catch (_) {
        err = '${p == 'gemini' ? 'Gemini' : 'Groq'}: network error.';
      }
    }
    throw AiException(err);
  }

  String _friendly(String who, int code, String body) {
    if (code == 401 || code == 403 || body.contains('API key not valid')) {
      return '$who API key galat hai ya access nahi hai (code $code).';
    }
    if (code == 429) return '$who ki limit khatam ho gayi, thodi der baad try karein.';
    return '$who error $code: ${body.length > 140 ? body.substring(0, 140) : body}';
  }

  Future<String> _grqModel({bool fresh = false}) async {
    if (!fresh && _qModel != null) return _qModel!;
    try {
      final res = await http
          .get(Uri.parse('https://api.groq.com/openai/v1/models'), headers: {'Authorization': 'Bearer $_qKey'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final ids = (jsonDecode(res.body)['data'] as List).map((e) => e['id'].toString()).toList();
        for (final p in ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant']) {
          if (ids.contains(p)) return _qModel = p;
        }
        const bad = ['whisper', 'guard', 'tts', 'playai', 'orpheus', 'safeguard', 'embed'];
        final ok = ids.where((i) => !bad.any(i.contains)).toList();
        if (ok.isNotEmpty) return _qModel = ok.first;
      }
    } catch (_) {}
    return _qModel = 'llama-3.1-8b-instant';
  }

  Future<String> _groq(List<Map<String, String>> msgs, {String? sys}) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final model = await _grqModel(fresh: attempt == 1);
      final res = await http
          .post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_qKey'},
            body: jsonEncode({
              'model': model,
              'temperature': 0.4,
              'messages': [
                {'role': 'system', 'content': sys ?? _sys},
                ...msgs,
              ],
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 200) {
        return jsonDecode(res.body)['choices'][0]['message']['content'].toString().trim();
      }
      if (attempt == 0 &&
          (res.statusCode == 404 || res.body.contains('model_not_found') || res.body.contains('decommissioned'))) {
        continue;
      }
      throw AiException(_friendly('Groq', res.statusCode, res.body));
    }
    throw AiException('Groq: koi chalne wala model nahi mila.');
  }

  Future<String> _gemModel({bool fresh = false}) async {
    if (!fresh && _gModel != null) return _gModel!;
    try {
      final res = await http
          .get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200'),
              headers: {'x-goog-api-key': _gKey})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final models = (jsonDecode(res.body)['models'] as List)
            .where((m) => (m['supportedGenerationMethods'] as List?)?.contains('generateContent') ?? false)
            .map((m) => m['name'].toString().replaceFirst('models/', ''))
            .toList();
        if (models.contains('gemini-flash-latest')) return _gModel = 'gemini-flash-latest';
        const bad = ['image', 'tts', 'embed', 'live', 'audio', 'exp', 'thinking', 'lite', 'preview', 'robotics', 'computer', '8b'];
        final flash = models.where((n) => n.startsWith('gemini') && n.contains('flash') && !bad.any(n.contains)).toList()
          ..sort((a, b) => b.compareTo(a));
        if (flash.isNotEmpty) return _gModel = flash.first;
      }
    } catch (_) {}
    return _gModel = 'gemini-flash-latest';
  }

  Future<String> _gemini(List<Map<String, String>> msgs, {String? sys, bool json = true}) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final model = await _gemModel(fresh: attempt == 1);
      final res = await http
          .post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
            headers: {'Content-Type': 'application/json', 'x-goog-api-key': _gKey},
            body: jsonEncode({
              'systemInstruction': {'parts': [{'text': sys ?? _sys}]},
              'contents': msgs
                  .map((m) => {
                        'role': m['role'] == 'assistant' ? 'model' : 'user',
                        'parts': [{'text': m['content']}]
                      })
                  .toList(),
              'generationConfig': {'temperature': 0.4, if (json) 'responseMimeType': 'application/json'},
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 200) {
        final parts = jsonDecode(res.body)['candidates']?[0]?['content']?['parts'] as List?;
        final t = parts?.map((p) => p['text'] ?? '').join().toString().trim() ?? '';
        if (t.isEmpty) throw AiException('Gemini ne khaali jawab diya, dobara poochiye.');
        return t;
      }
      if (attempt == 0 && (res.statusCode == 404 || res.body.contains('not found'))) continue;
      throw AiException(_friendly('Gemini', res.statusCode, res.body));
    }
    throw AiException('Gemini: koi chalne wala model nahi mila.');
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = 'Keys test ho rahi hain...';
    });
    final out = <String>[];
    const ping = [
      {'role': 'user', 'content': 'Say OK'}
    ];
    if (_gKey.isNotEmpty) {
      try {
        await _gemini(ping, sys: 'Reply OK', json: false);
        out.add('Gemini theek chal raha hai');
      } on AiException catch (e) {
        out.add(e.message);
      } catch (_) {
        out.add('Gemini network error');
      }
    }
    if (_qKey.isNotEmpty) {
      try {
        await _groq(ping, sys: 'Reply OK');
        out.add('Groq theek chal raha hai');
      } on AiException catch (e) {
        out.add(e.message);
      } catch (_) {
        out.add('Groq network error');
      }
    }
    if (out.isEmpty) out.add('Koi key save nahi hai');
    if (mounted) setState(() => _busy = false);
    _say("${out.join('. ')}, $_user.");
  }

  // ------------------------------------------------------------ dialogs
  Future<String?> _prompt(String title, String hint, {String initial = ''}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121216),
        title: Text(title),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text('OK', style: TextStyle(color: _accent))),
        ],
      ),
    );
  }

  Future<void> _setKey(bool gem) async {
    final v = await _prompt(gem ? 'Gemini API Key' : 'Groq API Key', gem ? 'AQ.xxxxxxxx...' : 'gsk_...');
    if (v == null || v.isEmpty) return;
    await _put(gem ? 'gkey' : 'qkey', v);
    setState(() {
      if (gem) {
        _gKey = v;
        _gModel = null;
      } else {
        _qKey = v;
        _qModel = null;
      }
    });
    _test();
  }

  Future<void> _pickTheme() async {
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: const Color(0xFF121216),
        title: const Text('Choose a theme'),
        children: [
          for (final e in _themes.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Row(children: [
                CircleAvatar(radius: 9, backgroundColor: e.value),
                const SizedBox(width: 12),
                Text(e.key),
              ]),
            ),
        ],
      ),
    );
    if (t == null) return;
    await _put('theme', t);
    setState(() => _themeName = t);
  }

  Future<void> _pickWall() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final f = await File(x.path).copy('${dir.path}/wall_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await _put('wall', f.path);
    setState(() => _wall = f.path);
  }

  void _sendTyped() {
    final t = _input.text.trim();
    _input.clear();
    FocusScope.of(context).unfocus();
    _process(t);
  }

  // ---------------------------------------------------------------- UI
  Widget _glass({required Widget child, VoidCallback? onTap, double r = 16, EdgeInsets pad = const EdgeInsets.all(14)}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(r),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                width: double.infinity,
                padding: pad,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(r),
                  border: Border.all(color: _accent.withOpacity(0.25)),
                ),
                child: child,
              ),
            ),
          ),
        ),
      );

  Widget _tile(IconData i, String t, String s, VoidCallback f) => _glass(
        onTap: f,
        child: Row(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: _accent.withOpacity(0.18)),
              child: Icon(i, color: _accent, size: 20)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            Text(s, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ])),
          const Icon(Icons.chevron_right, color: Colors.white38),
        ]),
      );

  Widget _section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 0, 8),
      child: Text(t, style: TextStyle(color: _accent, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.3)));

  Widget _head(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: _accent, fontWeight: FontWeight.w800, letterSpacing: 2)));

  Widget _bg() => Stack(fit: StackFit.expand, children: [
        if (_wall.isNotEmpty && File(_wall).existsSync())
          Image.file(File(_wall), fit: BoxFit.cover)
        else
          Container(
              decoration: BoxDecoration(
                  gradient: RadialGradient(
                      center: const Alignment(0, -0.3), radius: 1.2, colors: [_accent.withOpacity(0.28), Colors.black]))),
        Container(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withOpacity(0.25), Colors.black.withOpacity(0.82)]))),
      ]);

  Widget _home() => ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 20), children: [
        Row(children: [
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Hello, $_user', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
            const Text('How can I assist you today?', style: TextStyle(color: Colors.white54)),
          ])),
          const Icon(Icons.notifications_none, color: Colors.white70),
        ]),
        const SizedBox(height: 10),
        Center(
          child: GestureDetector(
            onTap: _mic,
            child: SizedBox(
              width: 260,
              height: 260,
              child: Stack(alignment: Alignment.center, children: [
                AnimatedBuilder(
                    animation: _anim,
                    builder: (_, __) => CustomPaint(
                        size: const Size(260, 260), painter: OrbPainter(_anim.value, _accent, _listening || _busy))),
                Icon(_listening ? Icons.graphic_eq : Icons.mic, color: Colors.white, size: 38),
              ]),
            ),
          ),
        ),
        Center(
            child: Text(_busy ? 'Soch raha hoon...' : (_status.isEmpty ? 'Tap the orb to speak' : _status),
                textAlign: TextAlign.center, maxLines: 6, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, height: 1.4))),
        if (_action.isNotEmpty)
          Center(child: Text(_action, style: TextStyle(color: _accent, fontSize: 11))),
        const SizedBox(height: 14),
        _glass(
          r: 30,
          pad: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _sendTyped(),
                    decoration: const InputDecoration(hintText: 'Ask MAX anything...', border: InputBorder.none))),
            IconButton(icon: Icon(Icons.send, color: _accent), onPressed: _sendTyped),
          ]),
        ),
        Row(children: [
          Expanded(
              child: _glass(
                  onTap: _toggleStandby,
                  child: Column(children: [
                    Icon(Icons.graphic_eq, color: _accent),
                    const SizedBox(height: 6),
                    Text(_standby ? 'Listening...' : 'Voice Mode', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]))),
          const SizedBox(width: 10),
          Expanded(
              child: _glass(
                  onTap: () => _tool('open_app', {'name': 'camera'}),
                  child: Column(children: [
                    Icon(Icons.camera_alt, color: _accent),
                    const SizedBox(height: 6),
                    const Text('Camera', style: TextStyle(fontWeight: FontWeight.w600)),
                  ]))),
        ]),
        _tile(Icons.rocket_launch, 'Mission Mode', 'Give MAX a goal to run autonomously', () async {
          final g = await _prompt('Mission Mode', 'Goal likho...');
          if (g != null && g.isNotEmpty) _process(g, mission: true);
        }),
        _tile(Icons.school, 'English Teacher AI', _teacher ? 'ON - practice chal rahi hai' : 'Learn English, speak, improve', () {
          setState(() => _teacher = !_teacher);
          _say(_teacher ? 'English teacher mode on. Let us practice. How was your day?' : 'English teacher mode off.');
        }),
        _section('QUICK DIRECTIVES'),
        Row(children: [
          Expanded(
              child: _glass(
                  onTap: () => _process('Deep research: mere area ka aaj ka mausam aur top khabrein web search karke batao'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.travel_explore, color: _accent),
                    const SizedBox(height: 6),
                    const Text('Deep Research', style: TextStyle(fontWeight: FontWeight.w700)),
                    const Text('Analyze local weather', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ]))),
          const SizedBox(width: 10),
          Expanded(
              child: _glass(
                  onTap: () async {
                    final q = await _prompt('Image Search', 'Kya dhundhna hai?');
                    if (q != null && q.isNotEmpty) _open('https://www.google.com/search?tbm=isch&q=${Uri.encodeComponent(q)}');
                  },
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.image_search, color: _accent),
                    const SizedBox(height: 6),
                    const Text('Image Search', style: TextStyle(fontWeight: FontWeight.w700)),
                    const Text('Search aesthetic spaces', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ]))),
        ]),
        _glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('NEURAL INSIGHT', style: TextStyle(color: _accent, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(_quotes[DateTime.now().day % _quotes.length], style: const TextStyle(fontSize: 15)),
        ])),
      ]);

  Widget _chatPage() => Column(children: [
        _head('TODAY'),
        Expanded(
          child: _chat.isEmpty
              ? const Center(child: Text('Abhi koi baat nahi hui.', style: TextStyle(color: Colors.white54)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _chat.length,
                  itemBuilder: (_, i) {
                    final m = _chat[i];
                    return _glass(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(m['role'] == 'user' ? 'You said' : 'assistant',
                            style: TextStyle(color: _accent, fontSize: 11, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        GestureDetector(
                            onTap: () {
                              setState(() => _chat.removeAt(i));
                              _saveChat();
                            },
                            child: const Icon(Icons.delete_outline, size: 18, color: Colors.white38)),
                      ]),
                      const SizedBox(height: 6),
                      Text(m['text'] ?? ''),
                    ]));
                  }),
        ),
      ]);

  Widget _quickPage() {
    final items = <List<dynamic>>[
      [Icons.flashlight_on, 'Flashlight', 'flashlight on karo'],
      [Icons.wb_sunny, 'Weather', 'aaj ka weather batao'],
      [Icons.chat, 'WhatsApp', 'whatsapp kholo'],
      [Icons.play_circle, 'YouTube', 'youtube kholo'],
      [Icons.map, 'Maps', 'maps kholo'],
      [Icons.camera_alt, 'Camera', 'camera kholo'],
      [Icons.alarm, 'Alarm', 'subah 6 baje ka alarm lagao'],
      [Icons.shopping_bag, 'Shopping', 'flipkart kholo'],
    ];
    final w = (MediaQuery.of(context).size.width - 50) / 2;
    return ListView(padding: const EdgeInsets.all(20), children: [
      _head('QUICK ACTIONS'),
      Wrap(spacing: 10, children: [
        for (final e in items)
          SizedBox(
              width: w,
              child: _glass(
                  onTap: () {
                    setState(() => _tab = 0);
                    _process(e[2] as String);
                  },
                  child: Column(children: [
                    Icon(e[0] as IconData, color: _accent, size: 28),
                    const SizedBox(height: 8),
                    Text(e[1] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]))),
      ]),
    ]);
  }

  Widget _settingsPage() => ListView(padding: const EdgeInsets.fromLTRB(20, 10, 20, 20), children: [
        _head('SETTINGS'),
        _section('PROFILE & ACCOUNT'),
        _tile(Icons.person, 'User Profile', 'Naam: $_user', () async {
          final v = await _prompt('Aapka naam', 'Naam likho', initial: _user);
          if (v != null && v.isNotEmpty) {
            await _put('user', v);
            setState(() => _user = v);
          }
        }),
        _section('VOICE & AI MODELS'),
        _tile(Icons.auto_awesome, 'Gemini API Key', _gKey.isEmpty ? 'Not set' : 'Saved', () => _setKey(true)),
        _tile(Icons.bolt, 'Groq API Key', _qKey.isEmpty ? 'Not set' : 'Saved', () => _setKey(false)),
        _tile(Icons.swap_horiz, 'AI Provider', 'Current: $_provider (tap to change)', () async {
          final n = _provider == 'auto' ? 'gemini' : (_provider == 'gemini' ? 'groq' : 'auto');
          await _put('provider', n);
          setState(() => _provider = n);
        }),
        _tile(Icons.network_check, 'Test Connection', 'Keys aur model check karo', _test),
        _section('WAKE WORD'),
        _glass(
            child: Row(children: [
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Wake Word', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            Text("Say 'Hey $_wake'", style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ])),
          Switch(value: _standby, activeColor: _accent, onChanged: (_) => _toggleStandby()),
        ])),
        _tile(Icons.record_voice_over, 'Custom Wake Word', 'Current: $_wake', () async {
          final v = await _prompt('Wake word (sirf naam)', 'jaise: power');
          if (v != null && v.isNotEmpty) {
            await _put('wake', v.toLowerCase());
            setState(() => _wake = v.toLowerCase());
          }
        }),
        _section('APPEARANCE'),
        _tile(Icons.palette, 'Orb Customization', 'Theme: $_themeName', _pickTheme),
        _tile(Icons.wallpaper, 'Wallpaper', 'Gallery se apni image chuno', _pickWall),
        _tile(Icons.hide_image, 'Remove Wallpaper', 'Default dark background', () async {
          await _put('wall', '');
          setState(() => _wall = '');
        }),
        _section('SECURITY & PRIVACY'),
        _tile(Icons.shield, 'Permissions', 'Manage all required permissions', () => openAppSettings()),
        _tile(Icons.delete_sweep, 'Clear Chat & Memory', 'Saari purani baatein hatao', () async {
          setState(() {
            _chat.clear();
            _memory.clear();
          });
          await _saveChat();
          await _putList('memory', _memory);
        }),
      ]);

  Widget _navBtn(IconData i, int t) => IconButton(
      icon: Icon(i, color: _tab == t ? _accent : Colors.white38, size: 26), onPressed: () => setState(() => _tab = t));

  Widget _nav() => SizedBox(
        height: 92,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 64,
              child: Container(
                  decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.88),
                      border: Border(top: BorderSide(color: _accent.withOpacity(0.25)))),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    _navBtn(Icons.home_rounded, 0),
                    _navBtn(Icons.chat_bubble_outline, 1),
                    const SizedBox(width: 80),
                    _navBtn(Icons.bolt, 2),
                    _navBtn(Icons.settings, 3),
                  ]))),
          Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                  child: GestureDetector(
                      onTap: _mic,
                      child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black,
                              border: Border.all(color: _accent, width: 2),
                              boxShadow: [BoxShadow(color: _accent.withOpacity(0.6), blurRadius: 18)]),
                          child: Center(
                              child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(colors: [Colors.orangeAccent, _accent])))))))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final pages = [_home, _chatPage, _quickPage, _settingsPage];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: _bg()),
        SafeArea(
            child: Column(children: [
          Expanded(child: pages[_tab]()),
          _nav(),
        ])),
        Positioned.fill(
            child: IgnorePointer(
                child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                        border: Border.all(color: _listening ? _accent : Colors.transparent, width: 3))))),
      ]),
    );
  }
}
