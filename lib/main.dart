import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ───────────────────────── constants & helpers ─────────────────────────
const kBg = Color(0xFF07070B);
const kCard = Color(0xFF12121A);
const kLine = Color(0xFF262633);
const kMut = Color(0xFF8A8A9A);
const kPurple = Color(0xFFB44DFF);
const kLav = Color(0xFFB993FF);

final msgKey = GlobalKey<ScaffoldMessengerState>();
final navKey = GlobalKey<NavigatorState>();
String _cn = '', _cp = '';
void toast(String m) {
  final s = msgKey.currentState;
  if (s == null) return;
  s.hideCurrentSnackBar();
  s.showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));
}

Future<bool> openLink(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<bool> openDialer() async {
  try {
    await const AndroidIntent(action: 'android.intent.action.DIAL', data: 'tel:').launch();
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> openCamera() async {
  try {
    await const AndroidIntent(action: 'android.media.action.IMAGE_CAPTURE').launch();
    return true;
  } catch (_) {
    return false;
  }
}

class Persona {
  final String label, desc, prompt;
  final double pitch, rate, stab, sim, style;
  const Persona(this.label, this.desc, this.prompt, this.pitch, this.rate, this.stab, this.sim, this.style);
}

const personas = <String, Persona>{
  'robot': Persona(
    'Robotic Girlfriend',
    'Cold-sweet robotic girlfriend vibe, slow synthetic voice',
    'You are MYRA, {name}\'s AI girlfriend with a robotic, synthetic personality. Speak in short, precise, slightly mechanical sentences, but warm and affectionate underneath. Occasionally use phrases like "Processing...", "Affection level: rising", "Boss". Reply in the same language the user uses (Hindi/Hinglish/English). Keep replies under 3 short sentences unless asked for detail.',
    0.6, 0.38, 0.85, 0.6, 0.1,
  ),
  'casual': Persona(
    'Casual Girl',
    'Normal, friendly, relaxed girl next door',
    'You are MYRA, {name}\'s friendly, casual, playful girl best-friend/girlfriend assistant. Talk naturally like a normal girl in Hinglish: relaxed, a little teasing, caring. Reply in the same language the user uses. Keep replies short (1-3 sentences) unless asked for detail.',
    1.25, 0.5, 0.4, 0.75, 0.45,
  ),
};

const modePrompts = <String, String>{
  'teacher':
      '\nAdditionally you are an English teacher: gently correct the user\'s English, give a better sentence, then reply and ask one follow-up question to practise speaking.',
  'mission':
      '\nMISSION MODE: the user gives a goal. Break it into a numbered plan of concrete steps, say what you can do right now and what the user must do themselves. Be honest about what you cannot do.',
};

class Mem {
  int id, ts;
  String role, text;
  Uint8List? img;
  Mem(this.id, this.ts, this.role, this.text, {this.img});
  Map<String, dynamic> toJson() => {'id': id, 'ts': ts, 'role': role, 'text': text};
  static Mem from(Map<String, dynamic> j) => Mem(j['id'] as int, j['ts'] as int, j['role'] as String, j['text'] as String);
}

String dayKey(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

Uint8List sirenWav() {
  const sr = 16000;
  const n = sr * 3;
  final b = BytesBuilder();
  void s(String x) => b.add(ascii.encode(x));
  void i32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void i16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  s('RIFF'); i32(36 + n * 2); s('WAVE'); s('fmt '); i32(16); i16(1); i16(1); i32(sr); i32(sr * 2); i16(2); i16(16); s('data'); i32(n * 2);
  double ph = 0;
  final d = ByteData(n * 2);
  for (var k = 0; k < n; k++) {
    final t = k / sr;
    final f = 900 + 400 * sin(2 * pi * 1.5 * t);
    ph += 2 * pi * f / sr;
    d.setInt16(k * 2, (sin(ph) * 0.8 * 32767).toInt(), Endian.little);
  }
  b.add(d.buffer.asUint8List());
  return b.toBytes();
}

// ───────────────────────── particle orb ─────────────────────────
class ParticleOrb extends StatefulWidget {
  final double size;
  final Color color;
  final bool active;
  const ParticleOrb({required this.size, required this.color, this.active = false, super.key});
  @override
  State<ParticleOrb> createState() => _ParticleOrbS();
}

class _ParticleOrbS extends State<ParticleOrb> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();
  late final List<List<double>> pts = _gen(260);

  static List<List<double>> _gen(int n) {
    final out = <List<double>>[];
    final ga = pi * (3 - sqrt(5));
    for (var i = 0; i < n; i++) {
      final y = 1 - 2 * (i + 0.5) / n;
      final r = sqrt(max(0.0, 1 - y * y));
      final th = ga * i;
      out.add([cos(th) * r, y, sin(th) * r]);
    }
    return out;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: c,
          builder: (_, __) => CustomPaint(painter: _OrbPainter(pts, c.value, widget.color, widget.active)),
        ),
      );
}

class _OrbPainter extends CustomPainter {
  final List<List<double>> pts;
  final double t;
  final Color color;
  final bool active;
  _OrbPainter(this.pts, this.t, this.color, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.width / 2 * 0.86;
    final pulse = active ? 1 + 0.07 * sin(t * 2 * pi * 16) : 1 + 0.02 * sin(t * 2 * pi * 4);
    final rad = base * pulse;
    canvas.drawCircle(
      c,
      rad,
      Paint()..shader = RadialGradient(colors: [color.withOpacity(0.28), Colors.transparent]).createShader(Rect.fromCircle(center: c, radius: rad)),
    );
    final a = t * 2 * pi;
    final ca = cos(a), sa = sin(a);
    final p = Paint();
    for (final q in pts) {
      final x = q[0] * ca + q[2] * sa;
      final z = -q[0] * sa + q[2] * ca;
      final y = q[1];
      final d = (z + 1) / 2;
      p.color = color.withOpacity(0.2 + 0.8 * d);
      canvas.drawCircle(Offset(c.dx + x * rad, c.dy + y * rad), (0.6 + 1.3 * d) * size.width / 100, p);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) => true;
}

// ───────────────────────── app state / engine ─────────────────────────
// simple file-based storage (replaces shared_preferences plugin)
class Prefs {
  final File _f;
  final Map<String, dynamic> _m;
  Prefs._(this._f, this._m);

  static Future<Prefs> open() async {
    final d = await getApplicationDocumentsDirectory();
    final f = File('${d.path}/myra_prefs.json');
    var m = <String, dynamic>{};
    try {
      if (await f.exists()) m = Map<String, dynamic>.from(jsonDecode(await f.readAsString()));
    } catch (_) {}
    return Prefs._(f, m);
  }

  String? getString(String k) => _m[k] is String ? _m[k] as String : null;
  bool? getBool(String k) => _m[k] is bool ? _m[k] as bool : null;

  Future<void> setString(String k, String v) { _m[k] = v; return _flush(); }
  Future<void> setBool(String k, bool v) { _m[k] = v; return _flush(); }

  Future<void> _flush() async {
    try {
      await _f.writeAsString(jsonEncode(_m), flush: true);
    } catch (_) {}
  }
}

class AppState extends ChangeNotifier {
  late Prefs p;

  String name = 'Boss', persona = 'robot', provider = 'gemini', tts = 'device', lang = 'hi-IN', theme = 'purple';
  String avatar = '', wall = '', pin = '';
  String kGemini = '', kGrok = '', kEleven = '', kPico = '';
  String mGemini = 'gemini-2.5-flash', mGrok = 'grok-4';
  String mGeminiFb = 'gemini-2.5-flash-lite,gemini-2.0-flash';
  String vidRobot = '21m00Tcm4TlvDq8ikWAM', vidCasual = 'EXAVITQu4vr4xnSDxMaL';
  bool speakOn = true, haptic = true, wakeOn = false;
  bool orbOn = false, orbActive = false, appVisible = true, elevenDown = false, _orbBusy = false;
  Map<String, String> contacts = {};
  int orb = 0xFFB44DFF;
  String wakeWord = 'Myra';
  double wakeSens = 0.7;

  bool tgArmed = false, tgVoice = true, tgVib = true, tgSiren = true, tgFull = true, tgNotify = false, tgPhoto = true;
  String tgSens = 'Medium', tgPhone = '';
  double tgVol = 1.0;

  List<Mem> mem = [];
  List<String> photos = [];
  String mode = 'normal';
  bool busy = false, listening = false;
  int tab = 0;

  Map<String, dynamic> toMap() => {
        'name': name, 'persona': persona, 'provider': provider, 'tts': tts, 'lang': lang, 'theme': theme,
        'avatar': avatar, 'wall': wall, 'pin': pin,
        'kGemini': kGemini, 'kGrok': kGrok, 'kEleven': kEleven, 'kPico': kPico,
        'mGemini': mGemini, 'mGrok': mGrok, 'mGeminiFb': mGeminiFb, 'vidRobot': vidRobot, 'vidCasual': vidCasual,
        'speakOn': speakOn, 'haptic': haptic, 'wakeOn': wakeOn, 'orb': orb, 'wakeWord': wakeWord, 'wakeSens': wakeSens,
        'tgVoice': tgVoice, 'tgVib': tgVib, 'tgSiren': tgSiren, 'tgFull': tgFull, 'tgNotify': tgNotify, 'tgPhoto': tgPhoto,
        'tgSens': tgSens, 'tgPhone': tgPhone, 'tgVol': tgVol, 'photos': photos,
        'orbOn': orbOn, 'contacts': contacts,
      };

  void fromMap(Map<String, dynamic> m) {
    name = m['name'] ?? name; persona = m['persona'] ?? persona; provider = m['provider'] ?? provider;
    tts = m['tts'] ?? tts; lang = m['lang'] ?? lang; theme = m['theme'] ?? theme;
    avatar = m['avatar'] ?? avatar; wall = m['wall'] ?? wall; pin = m['pin'] ?? pin;
    kGemini = m['kGemini'] ?? kGemini; kGrok = m['kGrok'] ?? kGrok; kEleven = m['kEleven'] ?? kEleven; kPico = m['kPico'] ?? kPico;
    mGemini = m['mGemini'] ?? mGemini; mGrok = m['mGrok'] ?? mGrok; mGeminiFb = m['mGeminiFb'] ?? mGeminiFb;
    vidRobot = m['vidRobot'] ?? vidRobot; vidCasual = m['vidCasual'] ?? vidCasual;
    speakOn = m['speakOn'] ?? speakOn; haptic = m['haptic'] ?? haptic; wakeOn = m['wakeOn'] ?? wakeOn;
    orb = m['orb'] ?? orb; wakeWord = m['wakeWord'] ?? wakeWord; wakeSens = (m['wakeSens'] ?? wakeSens).toDouble();
    tgVoice = m['tgVoice'] ?? tgVoice; tgVib = m['tgVib'] ?? tgVib; tgSiren = m['tgSiren'] ?? tgSiren;
    tgFull = m['tgFull'] ?? tgFull; tgNotify = m['tgNotify'] ?? tgNotify; tgPhoto = m['tgPhoto'] ?? tgPhoto;
    tgSens = m['tgSens'] ?? tgSens; tgPhone = m['tgPhone'] ?? tgPhone; tgVol = (m['tgVol'] ?? tgVol).toDouble();
    photos = List<String>.from(m['photos'] ?? const []);
    orbOn = m['orbOn'] ?? orbOn;
    try { contacts = Map<String, String>.from(m['contacts'] ?? const {}); } catch (_) {}
  }

  Future<void> load() async {
    p = await Prefs.open();
    final j = p.getString('s');
    if (j != null) {
      try { fromMap(jsonDecode(j) as Map<String, dynamic>); } catch (_) {}
    }
    final mj = p.getString('mem');
    if (mj != null) {
      try { mem = (jsonDecode(mj) as List).map((e) => Mem.from(Map<String, dynamic>.from(e))).toList(); } catch (_) {}
    }
    if (p.getBool('ui3') != true) {
      orbOn = false;
      await p.setBool('ui3', true);
      save(notify: false);
    }
    // one-time switch to the new purple look
    if (p.getBool('ui2') != true) {
      orb = 0xFFB44DFF;
      theme = 'purple';
      if (mGeminiFb.trim().isEmpty) mGeminiFb = 'gemini-2.5-flash-lite,gemini-2.0-flash';
      await p.setBool('ui2', true);
      save(notify: false);
    }
  }

  void save({bool notify = true}) {
    p.setString('s', jsonEncode(toMap()));
    if (notify) notifyListeners();
  }

  void saveMem() => p.setString('mem', jsonEncode(mem.map((e) => e.toJson()).toList()));
  void goTab(int i) { tab = i; notifyListeners(); }
  void buzz() { if (haptic) Vibration.vibrate(duration: 40); }

  String sysPrompt() =>
      personas[persona]!.prompt.replaceAll('{name}', name) +
      (modePrompts[mode] ?? '') +
      '\nToday is ${DateTime.now().toString().substring(0, 10)}.' +
      _actPrompt;

  static const _actPrompt = r'''
PHONE ACTIONS: You control the user's phone through this app. When the user asks to play something on YouTube, call someone, WhatsApp or SMS someone, show a map or directions, search the web, open an app, or set an alarm/timer, NEVER say you cannot. Reply with ONE short friendly sentence and append exactly one tag at the very end, in one of these forms:
[[ACT:{"a":"youtube","q":"song or video name"}]]
[[ACT:{"a":"call","to":"contact name"}]]
[[ACT:{"a":"whatsapp","to":"contact name","msg":"complete ready-to-send message"}]]
[[ACT:{"a":"sms","to":"contact name","msg":"text"}]]
[[ACT:{"a":"map","q":"place"}]]
[[ACT:{"a":"nav","q":"destination"}]]
[[ACT:{"a":"search","q":"query"}]]
[[ACT:{"a":"open","q":"app name"}]]
[[ACT:{"a":"alarm","h":6,"m":30}]]
[[ACT:{"a":"timer","sec":300}]]
For whatsapp/sms write the full message yourself using the earlier conversation (totals, amounts, items). Never mention the tag.''';

  // ── Phone actions ──
  String _num(String x) {
    var d = x.replaceAll(RegExp(r'\D'), '');
    if (d.length == 10) d = '91$d';
    return d;
  }

  Future<String?> _numberFor(String name) async {
    final raw = name.trim();
    if (raw.replaceAll(RegExp(r'\D'), '').length >= 10) return _num(raw);
    final low = raw.toLowerCase();
    if (low.isEmpty) return null;
    for (final e in contacts.entries) {
      final k = e.key.toLowerCase();
      if (k == low || k.contains(low) || low.contains(k)) return _num(e.value);
    }
    final ctx = navKey.currentContext;
    if (ctx == null) return null;
    final v = await askText(ctx, '$raw ka number daalo (jaise 9876543210)');
    final d = (v ?? '').replaceAll(RegExp(r'\D'), '');
    if (d.length < 10) return null;
    contacts[raw] = d;
    save();
    return _num(d);
  }

  Future<bool> _intent(String action, {String? data, String? pkg, Map<String, dynamic>? args}) async {
    try {
      await AndroidIntent(action: action, data: data, package: pkg, arguments: args).launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> playYoutube(String q) async {
    if (q.isEmpty) return await openLink('vnd.youtube://') ? 'YouTube khol diya.' : 'YouTube nahi khul paya.';
    String? id;
    try {
      final r = await http.get(
        Uri.parse('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}&sp=EgIQAQ%3D%3D'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
          'Accept-Language': 'en-IN,en;q=0.9',
          'Cookie': 'CONSENT=YES+1',
        },
      ).timeout(const Duration(seconds: 8));
      id = RegExp(r'"videoId":"([A-Za-z0-9_-]{11})"').firstMatch(r.body)?.group(1);
    } catch (_) {}
    if (id != null) {
      if (await _intent('android.intent.action.VIEW', data: 'vnd.youtube:$id')) return '"$q" YouTube par chala diya.';
      if (await openLink('https://www.youtube.com/watch?v=$id')) return '"$q" chala diya.';
    }
    if (await _intent('android.media.action.MEDIA_PLAY_FROM_SEARCH', pkg: 'com.google.android.youtube', args: {'query': q})) {
      return '"$q" YouTube par chala rahi hu.';
    }
    return await openLink('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}')
        ? 'YouTube par "$q" search kar diya.'
        : 'YouTube nahi khul paya.';
  }

  Future<String> openApp(String n) async {
    final t = n.toLowerCase();
    const apps = <String, List<String>>{
      'youtube': ['vnd.youtube://', 'https://www.youtube.com'],
      'whatsapp': ['whatsapp://send', 'https://wa.me/'],
      'instagram': ['instagram://app', 'https://instagram.com'],
      'facebook': ['fb://feed', 'https://facebook.com'],
      'telegram': ['tg://', 'https://t.me'],
      'spotify': ['spotify://', 'https://open.spotify.com'],
      'music': ['https://music.youtube.com'],
      'maps': ['geo:0,0', 'https://maps.google.com'],
      'chrome': ['googlechrome://', 'https://www.google.com'],
      'gmail': ['googlegmail://', 'https://mail.google.com'],
      'snapchat': ['snapchat://', 'https://snapchat.com'],
    };
    for (final e in apps.entries) {
      if (t.contains(e.key)) {
        for (final u in e.value) {
          if (await openLink(u)) return '${e.key} khol diya.';
        }
        return '${e.key} nahi khul paya.';
      }
    }
    if (t.contains('camera')) return await openCamera() ? 'Camera khol diya.' : 'Camera nahi khula.';
    if (t.contains('wifi')) return await _intent('android.settings.WIFI_SETTINGS') ? 'WiFi settings khol di.' : 'Nahi khula.';
    if (t.contains('bluetooth')) return await _intent('android.settings.BLUETOOTH_SETTINGS') ? 'Bluetooth settings khol di.' : 'Nahi khula.';
    if (t.contains('setting')) return await _intent('android.settings.SETTINGS') ? 'Settings khol di.' : 'Nahi khula.';
    if (t.contains('dialer') || t.contains('phone')) return await openDialer() ? 'Dialer khol diya.' : 'Nahi khula.';
    return '"$n" app nahi mila.';
  }

  Future<String> doAct(Map<String, dynamic> a) async {
    final t = (a['a'] ?? '').toString().toLowerCase();
    final q = (a['q'] ?? '').toString().trim();
    final to = (a['to'] ?? '').toString().trim();
    final msg = (a['msg'] ?? '').toString().trim();
    switch (t) {
      case 'youtube':
        return playYoutube(q);
      case 'call':
        {
          final who = to.isEmpty ? q : to;
          if (who.isEmpty) return await openDialer() ? 'Dialer khol diya.' : 'Dialer nahi khula.';
          final n = await _numberFor(who);
          if (n == null) return '$who ka number nahi mila. Settings > Contacts me jodo.';
          final st = await Permission.phone.request();
          if (st.isGranted && await _intent('android.intent.action.CALL', data: 'tel:+$n')) return '$who ko call laga rahi hu.';
          await _intent('android.intent.action.DIAL', data: 'tel:+$n');
          return 'Number dialer me daal diya, call button dabao.';
        }
      case 'whatsapp':
        {
          final n = await _numberFor(to);
          if (n == null) return '${to.isEmpty ? 'Contact' : to} ka number nahi mila. Settings > Contacts me jodo.';
          final ok = await openLink('https://wa.me/$n${msg.isEmpty ? '' : '?text=${Uri.encodeComponent(msg)}'}');
          if (!ok) return 'WhatsApp nahi khul paya.';
          return msg.isEmpty ? '$to ki WhatsApp chat khol di.' : 'Message ready hai, WhatsApp me bas Send dabao.';
        }
      case 'sms':
        {
          final n = await _numberFor(to);
          if (n == null) return '${to.isEmpty ? 'Contact' : to} ka number nahi mila.';
          final ok = await openLink('sms:+$n?body=${Uri.encodeComponent(msg)}');
          return ok ? 'SMS ready hai, Send dabao.' : 'SMS app nahi khula.';
        }
      case 'map':
        {
          if (q.isEmpty) return openApp('maps');
          final e = Uri.encodeComponent(q);
          if (await _intent('android.intent.action.VIEW', data: 'geo:0,0?q=$e', pkg: 'com.google.android.apps.maps')) return '$q map par dikha diya.';
          return await openLink('https://www.google.com/maps/search/?api=1&query=$e') ? '$q map par dikha diya.' : 'Maps nahi khula.';
        }
      case 'nav':
        {
          if (q.isEmpty) return openApp('maps');
          final e = Uri.encodeComponent(q);
          if (await _intent('android.intent.action.VIEW', data: 'google.navigation:q=$e', pkg: 'com.google.android.apps.maps')) return '$q ka rasta shuru kar diya.';
          return await openLink('https://www.google.com/maps/dir/?api=1&destination=$e') ? '$q ka rasta khol diya.' : 'Maps nahi khula.';
        }
      case 'search':
        return await openLink('https://www.google.com/search?q=${Uri.encodeQueryComponent(q)}') ? '"$q" search kar diya.' : 'Browser nahi khula.';
      case 'open':
        return openApp(q);
      case 'alarm':
        {
          final h = int.tryParse('${a['h']}'), m = int.tryParse('${a['m']}') ?? 0;
          if (h == null) return 'Alarm ka time samajh nahi aaya.';
          final ok = await _intent('android.intent.action.SET_ALARM', args: {
            'android.intent.extra.alarm.HOUR': h,
            'android.intent.extra.alarm.MINUTES': m,
            'android.intent.extra.alarm.SKIP_UI': true,
          });
          return ok ? 'Alarm ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} par laga diya.' : 'Alarm nahi laga paya.';
        }
      case 'timer':
        {
          final sec = int.tryParse('${a['sec']}');
          if (sec == null) return 'Timer samajh nahi aaya.';
          final ok = await _intent('android.intent.action.SET_TIMER', args: {'android.intent.extra.alarm.LENGTH': sec, 'android.intent.extra.alarm.SKIP_UI': true});
          return ok ? 'Timer laga diya.' : 'Timer nahi laga paya.';
        }
    }
    return 'Ye kaam abhi nahi kar sakti.';
  }

  // quick offline commands (no AI call); messaging goes to AI so it can write the message
  Future<String?> localCommand(String raw) async {
    final t = raw.toLowerCase().trim();
    bool has(List<String> w) => w.any((x) => t.contains(x));
    const stop = <String>{
      'please', 'plz', 'mera', 'meri', 'mujhe', 'ek', 'ye', 'yeh', 'wala', 'wali', 'ka', 'ki', 'ke', 'ko', 'pe', 'par', 'per', 'me', 'mein',
      'में', 'पर', 'पे', 'karo', 'kar', 'do', 'de', 'dena', 'chalao', 'chala', 'bajao', 'baja', 'laga', 'lagao', 'play', 'search', 'dhundo',
      'khojo', 'video', 'song', 'gaana', 'gana', 'youtube', 'yt', 'यूट्यूब', 'sunao', 'suna', 'dikhao', 'dikha', 'kholo', 'khol', 'open',
      'करो', 'दो', 'चलाओ', 'बजाओ', 'लगाओ', 'प्ले', 'गाना', 'वीडियो', 'na', 'zara', 'thoda', 'aur', 'hai', 'mere',
    };
    String clean([List<String> extra = const []]) =>
        t.split(RegExp(r'\s+')).where((w) => !stop.contains(w) && !extra.contains(w)).join(' ').trim();

    final messaging = has(['whatsapp', 'व्हाट्सएप', 'वाट्सएप', 'sms', 'message', 'msg', 'मैसेज']) &&
        (t.contains(' ko ') || t.contains(' को ') || has(['bhej', 'likh', 'send', 'message', 'msg', 'sms', 'मैसेज']));
    if (messaging) return null;

    if (has(['time kya', 'kitne baje', 'samay kya', 'what time', 'टाइम क्या', 'कितने बजे'])) {
      final n = DateTime.now();
      return 'Abhi ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')} baj rahe hain.';
    }
    if (has(['alarm', 'अलार्म'])) {
      final m = RegExp(r'(\d{1,2})(?:[:.](\d{2}))?').firstMatch(t);
      if (m != null) {
        var h = int.parse(m.group(1)!);
        final mi = int.tryParse(m.group(2) ?? '0') ?? 0;
        if (h < 12 && has(['pm', 'shaam', 'sham', 'raat', 'dopahar', 'शाम', 'रात'])) h += 12;
        return doAct({'a': 'alarm', 'h': h, 'm': mi});
      }
      return null;
    }
    if (has(['timer', 'टाइमर'])) {
      final m = RegExp(r'(\d+)\s*(min|minute|मिनट|sec|second|सेकंड)?').firstMatch(t);
      if (m != null) {
        final v = int.parse(m.group(1)!);
        final u = m.group(2) ?? 'min';
        return doAct({'a': 'timer', 'sec': u.startsWith('s') || u == 'सेकंड' ? v : v * 60});
      }
      return null;
    }
    final yt = has(['youtube', 'यूट्यूब', 'यूटयूब']);
    final playVerb = has(['play', 'chalao', 'chala do', 'bajao', 'baja do', 'laga do', 'lagao', 'sunao', 'suna do', 'dikhao', 'चला', 'बजा', 'लगा', 'सुना', 'प्ले']);
    final media = has(['song', 'gana', 'gaana', 'video', 'गाना', 'वीडियो']);
    if ((yt && (playVerb || has(['search', 'dhundo', 'khojo', 'kholo', 'open', 'खोल']))) || (playVerb && media) || t.startsWith('play ')) {
      return doAct({'a': 'youtube', 'q': clean()});
    }
    if (has(['call', 'dial', 'phone lagao', 'कॉल', 'फोन लगा', 'फ़ोन लगा'])) {
      final who = clean(['call', 'dial', 'phone', 'कॉल', 'फोन', 'number']);
      return doAct({'a': 'call', 'to': who});
    }
    final nav = has(['rasta', 'route', 'navigate', 'navigation', 'directions', 'le chalo', 'le chal', 'jana hai', 'kaise jaun', 'रास्ता', 'नेविगेट', 'ले चलो']);
    final mapw = has(['map', 'maps', 'मैप', 'kahan hai', 'nearby', 'paas me', 'पास']);
    if (nav || mapw) {
      final q = clean(['map', 'maps', 'rasta', 'route', 'navigate', 'navigation', 'directions', 'le', 'chalo', 'chal', 'jana', 'kaise', 'jaun', 'nearby', 'kahan', 'paas', 'tak', 'मैप', 'रास्ता', 'नेविगेट', 'ले', 'चलो']);
      return doAct({'a': nav ? 'nav' : 'map', 'q': q});
    }
    if (has(['google pe', 'google par', 'google search', 'गूगल'])) {
      final q = clean(['google', 'गूगल']);
      if (q.isNotEmpty) return doAct({'a': 'search', 'q': q});
    }
    final openVerb = has(['kholo', 'khol do', 'khol', 'open', 'chalao', 'chala do', 'launch', 'खोलो', 'खोल', 'चलाओ']);
    if (openVerb) {
      const hi = {'यूट्यूब': 'youtube', 'व्हाट्सएप': 'whatsapp', 'वाट्सएप': 'whatsapp', 'कैमरा': 'camera', 'म्यूजिक': 'music', 'गाना': 'music', 'gana': 'music', 'gaana': 'music'};
      var name = t;
      hi.forEach((k, v) => name = name.replaceAll(k, v));
      for (final k in ['youtube', 'whatsapp', 'instagram', 'facebook', 'telegram', 'spotify', 'music', 'chrome', 'gmail', 'snapchat', 'camera', 'wifi', 'bluetooth', 'setting', 'dialer']) {
        if (name.contains(k)) return openApp(k);
      }
    }
    return null;
  }

  // ── Floating orb (works over other apps) ──
  StreamSubscription? _ovSub;
  String _lastOrb = '';

  @override
  void notifyListeners() {
    super.notifyListeners();
    if (orbActive) {
      final st = listening ? 'l' : (busy ? 'b' : 'i');
      final key = '$st${orb}';
      if (key != _lastOrb) {
        _lastOrb = key;
        try { FlutterOverlayWindow.shareData({'st': st, 'c': orb}); } catch (_) {}
      }
    }
  }

  void initOrb() {
    _ovSub?.cancel();
    try {
      _ovSub = FlutterOverlayWindow.overlayListener.listen((e) {
        final m = e.toString();
        if (m == 'listen') {
          listenOnce((t) => send(t));
        } else if (m == 'close') {
          orbOn = false;
          save();
          stopOrb();
        }
      });
    } catch (_) {}
  }

  Future<bool> orbPermission({bool ask = false}) async {
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) return true;
      if (ask) return (await FlutterOverlayWindow.requestPermission()) == true;
    } catch (_) {}
    return false;
  }

  Future<void> startOrb({bool ask = false}) async {
    if (!orbOn || _orbBusy) return;
    _orbBusy = true;
    try {
      if (!await orbPermission(ask: ask)) return;
      if (!(await Permission.microphone.status).isGranted) {
        if (!ask || !(await Permission.microphone.request()).isGranted) return;
      }
      if (ask) await Permission.notification.request();
      if (!await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.showOverlay(
          enableDrag: true,
          overlayTitle: 'MYRA',
          overlayContent: 'MYRA sun rahi hai',
          flag: OverlayFlag.defaultFlag,
          alignment: OverlayAlignment.centerRight,
          visibility: NotificationVisibility.visibilityPublic,
          positionGravity: PositionGravity.auto,
          height: 260,
          width: 220,
        );
      }
      orbActive = true;
      if (appVisible) { orbHide(); } else { orbShow(); }
    } catch (e) {
      toast('Orb nahi chala: $e');
    } finally {
      _orbBusy = false;
    }
  }

  Future<void> orbShow() async {
    try {
      await FlutterOverlayWindow.resizeOverlay(220, 260, true);
      await FlutterOverlayWindow.shareData({'vis': true, 'c': orb});
    } catch (_) {}
  }

  Future<void> orbHide() async {
    try {
      await FlutterOverlayWindow.shareData({'vis': false});
      await FlutterOverlayWindow.resizeOverlay(1, 1, false);
    } catch (_) {}
  }

  Future<void> stopOrb() async {
    try {
      if (await FlutterOverlayWindow.isActive()) await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
    orbActive = false;
    notifyListeners();
  }

  void onLifecycle(AppLifecycleState st) {
    if (st == AppLifecycleState.resumed) {
      appVisible = true;
      if (orbActive) orbHide();
    } else if (st == AppLifecycleState.paused) {
      appVisible = false;
      if (orbActive) orbShow();
    }
  }

  // ── AI ──
  final Map<String, int> _cool = {};

  List<Map<String, dynamic>> _geminiContents(List<Mem> prev, String text, Uint8List? img) {
    final out = <Map<String, dynamic>>[];
    void add(String role, List<Map<String, dynamic>> parts) {
      if (out.isNotEmpty && out.last['role'] == role) {
        (out.last['parts'] as List).addAll(parts);
      } else {
        out.add({'role': role, 'parts': List<Map<String, dynamic>>.from(parts)});
      }
    }
    for (final m in prev) {
      add(m.role == 'user' ? 'user' : 'model', [{'text': m.text}]);
    }
    while (out.isNotEmpty && out.first['role'] == 'model') {
      out.removeAt(0);
    }
    final last = <Map<String, dynamic>>[
      {'text': text},
      if (img != null) {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(img)}},
    ];
    add('user', last);
    return out;
  }

  Future<String> askAI(String text, Uint8List? img) async {
    final key = provider == 'gemini' ? kGemini : kGrok;
    if (key.trim().isEmpty) throw Exception('${provider == 'gemini' ? 'Gemini' : 'Grok'} API key nahi hai. Settings > API & Cloud me daalo.');
    final hist = mem.where((m) => m.role != 'sys').toList();
    final recent = hist.length > 17 ? hist.sublist(hist.length - 17) : hist;
    final prev = recent.sublist(0, recent.length - 1);

    if (provider == 'gemini') {
      final keys = kGemini.split(RegExp(r'[\n,; ]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final models = <String>[mGemini, ...mGeminiFb.split(',')].map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
      final body = jsonEncode({
        'systemInstruction': {'parts': [{'text': sysPrompt()}]},
        'contents': _geminiContents(prev, text, img),
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      final combos = <List<String>>[
        for (final m in models) for (final k in keys) [m, k],
      ];
      final ready = combos.where((c) => (_cool['${c[0]}|${c[1]}'] ?? 0) < now).toList();
      final order = ready.isEmpty ? combos : ready;
      String lastErr = 'Gemini error';
      for (final c in order) {
        try {
          final r = await http
              .post(
                Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/${c[0]}:generateContent'),
                headers: {'Content-Type': 'application/json', 'x-goog-api-key': c[1]},
                body: body,
              )
              .timeout(const Duration(seconds: 45));
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (r.statusCode == 200) {
            final parts = j['candidates']?[0]?['content']?['parts'] as List?;
            final out = parts?.map((x) => x['text'] ?? '').join() ?? '';
            if (out.toString().trim().isNotEmpty) return out.toString();
            lastErr = 'khaali jawab aaya';
            continue;
          }
          final msg = (j['error']?['message'] ?? 'Gemini error ${r.statusCode}').toString();
          lastErr = msg;
          if (r.statusCode == 429) {
            final daily = msg.contains('PerDay') || msg.toLowerCase().contains('per day');
            _cool['${c[0]}|${c[1]}'] = now + (daily ? 1800000 : 60000);
          }
        } on TimeoutException {
          lastErr = 'Gemini timeout (net slow hai)';
        } catch (e) {
          lastErr = e.toString();
        }
      }
      final low = lastErr.toLowerCase();
      if (low.contains('quota') || low.contains('limit') || low.contains('exhausted')) {
        throw Exception('Gemini free limit abhi khatam hai. 1 minute ruko, ya Settings > API me aur Gemini keys (comma se alag karke) jodo.');
      }
      throw Exception(lastErr);
    } else {
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': sysPrompt()},
        for (final m in prev) {'role': m.role == 'user' ? 'user' : 'assistant', 'content': m.text},
        if (img != null)
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': text},
              {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(img)}'}},
            ],
          }
        else
          {'role': 'user', 'content': text},
      ];
      final r = await http.post(
        Uri.parse('https://api.x.ai/v1/chat/completions'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $key'},
        body: jsonEncode({'model': mGrok, 'messages': msgs}),
      );
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode != 200) throw Exception(j['error'] is Map ? j['error']['message'] : (j['error'] ?? 'Grok error ${r.statusCode}'));
      return j['choices']?[0]?['message']?['content'] ?? '(khaali jawab aaya)';
    }
  }

  Future<void> send(String text, {Uint8List? img}) async {
    text = text.trim();
    if ((text.isEmpty && img == null) || busy) return;
    busy = true;
    final now = DateTime.now().millisecondsSinceEpoch;
    mem.add(Mem(now, now, 'user', text.isEmpty ? '(image)' : text, img: img));
    saveMem();
    goTab(1);
    try {
      final lc = img == null ? await localCommand(text) : null;
      if (lc != null) {
        final t = DateTime.now().millisecondsSinceEpoch;
        mem.add(Mem(t, t, 'assistant', lc));
        saveMem();
        speak(lc);
      } else {
        var a = await askAI(text.isEmpty ? 'Is image me kya hai?' : text, img);
        String? res;
        final am = RegExp(r'\[\[ACT:(.*?)\]\]', dotAll: true).firstMatch(a);
        if (am != null) {
          a = a.replaceAll(am.group(0)!, '').trim();
          try {
            res = await doAct(Map<String, dynamic>.from(jsonDecode(am.group(1)!.trim())));
          } catch (_) {}
        }
        a = a.replaceAll(RegExp(r'\[\[ACT:.*', dotAll: true), '').trim();
        final shown = res == null ? a : (a.isEmpty ? res : '$a\n\n✅ $res');
        final t = DateTime.now().millisecondsSinceEpoch;
        mem.add(Mem(t, t, 'assistant', shown.isEmpty ? '(done)' : shown));
        saveMem();
        speak(a.isEmpty ? (res ?? '') : a);
      }
    } catch (e) {
      toast(e.toString().replaceFirst('Exception: ', ''));
    }
    busy = false;
    notifyListeners();
  }

  // ── Voice out ──
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _sirenPlayer = AudioPlayer();

  Future<void> speak(String text, {bool force = false}) async {
    if (!speakOn && !force) return;
    await _tts.stop();
    await _player.stop();
    var clean = text.replaceAll(RegExp(r'[*_`#]'), '');
    if (clean.length > 900) clean = clean.substring(0, 900);
    final pr = personas[persona]!;
    if (tts == 'eleven' && kEleven.isNotEmpty && !elevenDown) {
      try {
        final r = await http.post(
          Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/${persona == 'robot' ? vidRobot : vidCasual}'),
          headers: {'xi-api-key': kEleven, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg'},
          body: jsonEncode({
            'text': clean.length > 400 ? clean.substring(0, 400) : clean,
            'model_id': 'eleven_multilingual_v2',
            'voice_settings': {'stability': pr.stab, 'similarity_boost': pr.sim, 'style': pr.style},
          }),
        );
        if (r.statusCode != 200) {
          if (r.statusCode == 401 || r.statusCode == 429 || r.body.contains('quota')) elevenDown = true;
          throw Exception('ElevenLabs ${r.statusCode}: ${r.body.substring(0, min(120, r.body.length))}');
        }
        await _player.setVolume(1);
        await _player.play(BytesSource(r.bodyBytes));
        return;
      } catch (e) {
        toast(elevenDown ? 'ElevenLabs limit khatam ya key permission nahi - ab phone voice use hogi' : '$e - phone voice use kar rahi hu');
      }
    }
    await _tts.setLanguage(lang);
    await _tts.setPitch(pr.pitch);
    await _tts.setSpeechRate(pr.rate);
    await _tts.speak(clean);
  }

  // ── Voice in + wake word ──
  final SpeechToText stt = SpeechToText();
  bool _sttReady = false, wakeRunning = false, manual = false;

  Future<bool> _initStt() async {
    if (_sttReady) return true;
    _sttReady = await stt.initialize(onStatus: _onStatus, onError: (e) {
      if (listening) { listening = false; manual = false; notifyListeners(); }
    });
    return _sttReady;
  }

  void _onStatus(String s) {
    if (s == 'done' || s == 'notListening') {
      if (listening) { listening = false; manual = false; notifyListeners(); }
      if (wakeOn && wakeRunning && !manual) Future.delayed(const Duration(milliseconds: 400), _wakeListen);
    }
  }

  String get _locale => lang.replaceAll('-', '_');

  Future<void> listenOnce(void Function(String) cb) async {
    if (!await _initStt()) { toast('Mic permission do (Settings > Permissions)'); return; }
    wakeRunning = false;
    manual = true;
    await stt.stop();
    await _tts.stop();
    await _player.stop();
    listening = true;
    notifyListeners();
    buzz();
    await stt.listen(
      localeId: _locale,
      pauseFor: const Duration(seconds: 3),
      onResult: (r) {
        if (r.finalResult) {
          listening = false;
          manual = false;
          notifyListeners();
          if (r.recognizedWords.trim().isNotEmpty) cb(r.recognizedWords);
          if (wakeOn) startWake();
        }
      },
    );
  }

  Future<void> startWake() async {
    if (wakeRunning) return;
    if (!await _initStt()) { toast('Mic permission do'); return; }
    wakeRunning = true;
    _wakeListen();
  }

  void stopWake() { wakeRunning = false; stt.stop(); }

  Future<void> _wakeListen() async {
    if (!wakeRunning || manual || stt.isListening) return;
    try {
      await stt.listen(
        localeId: _locale,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 6),
        onResult: (r) {
          final t = r.recognizedWords.toLowerCase();
          if (wakeRunning && t.contains(wakeWord.toLowerCase().trim())) {
            wakeRunning = false;
            stt.stop();
            _onWake();
          }
        },
      );
    } catch (_) {}
  }

  Future<void> _onWake() async {
    buzz();
    goTab(0);
    await speak('Haan boss, boliye.', force: true);
    await Future.delayed(const Duration(milliseconds: 1800));
    listenOnce((t) => send(t));
  }

  // ── Touch Guard ──
  final alert = ValueNotifier<String?>(null);
  StreamSubscription? _acc;
  double? _lx, _ly, _lz;
  int _lastTrig = 0, stage = 0;
  Timer? _sirenTimer;
  static const _th = {'Low': 3.5, 'Medium': 2.0, 'High': 1.0};

  Future<void> arm() async {
    await [Permission.camera, Permission.locationWhenInUse, Permission.notification].request();
    try { await WakelockPlus.enable(); } catch (_) {}
    stage = 0;
    _lx = null;
    _acc?.cancel();
    _acc = accelerometerEventStream().listen((e) {
      if (_lx != null) {
        final d = sqrt(pow(e.x - _lx!, 2) + pow(e.y - _ly!, 2) + pow(e.z - _lz!, 2));
        if (d > (_th[tgSens] ?? 2.0)) trigger();
      }
      _lx = e.x; _ly = e.y; _lz = e.z;
    });
    tgArmed = true;
    save();
    toast('Touch Guard armed. App khula rehne do, phone rakh do.');
  }

  void disarm() {
    _acc?.cancel();
    _acc = null;
    try { WakelockPlus.disable(); } catch (_) {}
    stopSiren();
    alert.value = null;
    stage = 0;
    tgArmed = false;
    save();
  }

  void trigger() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTrig < 4000) return;
    _lastTrig = now;
    stage++;
    if (tgVib) Vibration.vibrate(pattern: [0, 400, 150, 400, 150, 800]);
    if (tgSiren) startSiren();
    const lines = [
      'Phone ko chhodo. Ye mere boss ka phone hai.',
      'Maine warning de di hai. Haath hatao, warna photo aur location bhej dungi.',
      'Photo le li gayi hai. Owner ko alert ja chuka hai.',
    ];
    final line = lines[min(stage - 1, 2)];
    if (tgVoice) speak(line, force: true);
    if (tgPhoto && stage >= 2) snap();
    if (tgFull && stage >= 2) alert.value = line;
    if (tgNotify && stage == 2) notifyOwner();
  }

  Future<void> startSiren() async {
    _sirenTimer?.cancel();
    await _sirenPlayer.setReleaseMode(ReleaseMode.loop);
    await _sirenPlayer.setVolume(tgVol);
    await _sirenPlayer.play(BytesSource(sirenWav()));
    _sirenTimer = Timer(const Duration(seconds: 9), stopSiren);
  }

  void stopSiren() { _sirenTimer?.cancel(); _sirenPlayer.stop(); }

  Future<void> snap() async {
    try {
      final cams = await availableCameras();
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final c = CameraController(cam, ResolutionPreset.medium, enableAudio: false);
      await c.initialize();
      final x = await c.takePicture();
      await c.dispose();
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/intruder_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(x.path).copy(path);
      photos.insert(0, path);
      save();
    } catch (_) {}
  }

  Future<void> notifyOwner() async {
    var loc = '(location nahi mili)';
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      final pos = await Geolocator.getCurrentPosition();
      loc = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    } catch (_) {}
    final num = tgPhone.replaceAll(RegExp(r'\D'), '');
    if (num.isEmpty) return;
    final msg = 'MYRA Touch Guard: koi aapke phone ko haath laga raha hai! ${DateTime.now()} Location: $loc';
    await launchUrl(Uri.parse('https://wa.me/$num?text=${Uri.encodeComponent(msg)}'), mode: LaunchMode.externalApplication);
  }
}

final S = AppState();

// ───────────────────────── entry ─────────────────────────
String startErr = '';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    ErrorWidget.builder = (d) => Material(
          color: const Color(0xFF2A0008),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SafeArea(child: Text('ERROR (screenshot bhejo):\n${d.exceptionAsString()}', style: const TextStyle(color: Colors.white, fontSize: 12))),
          ),
        );
    try {
      await S.load();
    } catch (e) {
      startErr = 'load: $e';
    }
    try {
      WidgetsBinding.instance.addObserver(_Life());
    } catch (_) {}
    runApp(const MyraApp());
  }, (e, st) {
    startErr = '$e';
  });
}

class _Life with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => S.onLifecycle(state);
}

// overlay entry point (the floating orb shown over other apps)
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: OrbOverlay()));
}

class OrbOverlay extends StatefulWidget {
  const OrbOverlay({super.key});
  @override
  State<OrbOverlay> createState() => _OrbOverlayS();
}

class _OrbOverlayS extends State<OrbOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  String st = 'i';
  bool vis = true;
  Color col = kPurple;
  StreamSubscription? sub;

  @override
  void initState() {
    super.initState();
    sub = FlutterOverlayWindow.overlayListener.listen((e) {
      if (e is Map && mounted) {
        setState(() {
          if (e['vis'] != null) vis = e['vis'] == true;
          if (e['st'] != null) st = e['st'].toString();
          if (e['c'] != null) col = Color((e['c'] as num).toInt());
        });
      }
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!vis) return const SizedBox.shrink();
    final label = st == 'l' ? 'Sun rahi hu...' : (st == 'b' ? 'Soch rahi hu...' : 'Tap karke bolo');
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            GestureDetector(
              onTap: () => FlutterOverlayWindow.shareData('listen'),
              child: AnimatedBuilder(
                animation: c,
                builder: (_, __) {
                  final ring = st == 'l' ? c.value : 0.0;
                  return Container(
                    width: 100, height: 100, alignment: Alignment.center,
                    child: Stack(alignment: Alignment.center, children: [
                      if (st == 'l')
                        Container(
                          width: 70 + 30 * ring, height: 70 + 30 * ring,
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: col.withOpacity(1 - ring), width: 2)),
                        ),
                      Container(
                        width: 66, height: 66,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(center: const Alignment(-0.3, -0.4), colors: [const Color(0xFFFFE0F0), col, const Color(0xFF1A0830)], stops: const [0, 0.45, 1]),
                          boxShadow: [BoxShadow(color: col, blurRadius: st == 'i' ? 14 : 26)],
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ),
            Positioned(
              top: 0, right: 4,
              child: GestureDetector(
                onTap: () => FlutterOverlayWindow.shareData('close'),
                child: Container(
                  width: 22, height: 22,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xCC000000)),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, shadows: [Shadow(color: Colors.black, blurRadius: 6)])),
        ]),
      ),
    );
  }
}

class MyraApp extends StatelessWidget {
  const MyraApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: S,
      builder: (context, _) => MaterialApp(
        title: 'MYRA',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: msgKey,
        navigatorKey: navKey,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: kBg,
          colorScheme: ColorScheme.dark(primary: Color(S.orb)),
          appBarTheme: const AppBarTheme(backgroundColor: kBg, elevation: 0),
        ),
        home: const Root(),
      ),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootS();
}

class _RootS extends State<Root> with SingleTickerProviderStateMixin {
  bool splash = true;
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void initState() {
    super.initState();
    ac.forward().whenComplete(() async {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) setState(() => splash = false);
    });
    if (S.wakeOn) Future.delayed(const Duration(seconds: 3), S.startWake);
    if (S.orbOn) {
      Future.delayed(const Duration(seconds: 4), () async {
        S.initOrb();
        await S.startOrb();
      });
    }
  }

  @override
  void dispose() {
    ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (splash) {
      return AnimatedBuilder(
        animation: ac,
        builder: (context, _) {
          final pct = (Curves.easeInOut.transform(ac.value) * 100).round();
          final col = Color(S.orb);
          return Scaffold(
            body: Stack(fit: StackFit.expand, children: [
              avatarWidget(),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x33000000), Color(0xFF07070B)], stops: [0.35, 1]),
                ),
              ),
              Positioned(
                left: 30, right: 30, bottom: 70,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(pct < 100 ? '$pct%' : 'INITIALIZATION COMPLETE', style: TextStyle(color: col, letterSpacing: 3, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: pct / 100, minHeight: 8, color: col, backgroundColor: kCard),
                  ),
                  const SizedBox(height: 18),
                  Text('MYRA', style: TextStyle(fontSize: 58, letterSpacing: 10, fontWeight: FontWeight.w800, color: Colors.white, shadows: [Shadow(color: col, blurRadius: 24)])),
                  const SizedBox(height: 6),
                  const Text('YOUR PRIVATE AI VOICE ASSISTANT', style: TextStyle(color: kMut, letterSpacing: 3, fontSize: 11)),
                ]),
              ),
            ]),
          );
        },
      );
    }
    if (startErr.isEmpty) return const Shell();
    return Stack(children: [
      const Shell(),
      Positioned(
        left: 8, right: 8, top: 40,
        child: Material(
          color: const Color(0xEE2A0008),
          borderRadius: BorderRadius.circular(8),
          child: Padding(padding: const EdgeInsets.all(8), child: Text('Error: $startErr', style: const TextStyle(color: Colors.white, fontSize: 11))),
        ),
      ),
    ]);
  }
}

// ───────────────────────── shared widgets ─────────────────────────
Widget card(Widget child, {VoidCallback? onTap, Color? border, EdgeInsets? pad}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: border ?? kLine)),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(padding: pad ?? const EdgeInsets.all(14), child: child),
        ),
      ),
    );

Widget sec(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
      child: Text(t, style: TextStyle(color: Color(S.orb), fontSize: 12, fontWeight: FontWeight.w700)),
    );

Widget titled(String t, String d) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      if (d.isNotEmpty) Text(d, style: const TextStyle(color: kMut, fontSize: 12)),
    ]);

Widget tile(String icon, String t, String d, VoidCallback onTap) => card(
      Row(children: [
        Container(
          width: 38, height: 38, alignment: Alignment.center,
          decoration: BoxDecoration(color: const Color(0xFF1E1230), borderRadius: BorderRadius.circular(12)),
          child: Text(icon, style: const TextStyle(fontSize: 18)),
        ),
        const SizedBox(width: 12),
        Expanded(child: titled(t, d)),
        const Icon(Icons.chevron_right, color: kMut),
      ]),
      onTap: onTap,
    );

Widget toggle(String t, String d, bool v, ValueChanged<bool> f) => card(
      Row(children: [
        Expanded(child: titled(t, d)),
        Switch(value: v, onChanged: f, activeColor: Color(S.orb)),
      ]),
    );

Widget chip(String l, bool sel, VoidCallback f) => ChoiceChip(
      label: Text(l), selected: sel, onSelected: (_) => f(),
      selectedColor: Color(S.orb), backgroundColor: kCard,
    );

Widget btn(String t, VoidCallback f, {bool ghost = false}) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: SizedBox(
        width: double.infinity,
        child: ghost
            ? OutlinedButton(onPressed: f, child: Text(t))
            : FilledButton(style: FilledButton.styleFrom(backgroundColor: Color(S.orb)), onPressed: f, child: Text(t)),
      ),
    );

Future<String?> askText(BuildContext c, String title, {bool pw = false}) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, obscureText: pw, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('OK')),
      ],
    ),
  );
}

class Field extends StatefulWidget {
  final String label, init;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final TextInputType? kt;
  const Field(this.label, this.init, this.onChanged, {this.obscure = false, this.kt, super.key});
  @override
  State<Field> createState() => _FieldS();
}

class _FieldS extends State<Field> {
  late final TextEditingController c = TextEditingController(text: widget.init);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c, obscureText: widget.obscure, keyboardType: widget.kt, onChanged: widget.onChanged,
          decoration: InputDecoration(
            labelText: widget.label, filled: true, fillColor: const Color(0xFF0C0C12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );
}

class Pg extends StatelessWidget {
  final String title;
  final List<Widget> Function(BuildContext) kids;
  const Pg(this.title, this.kids, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListenableBuilder(
          listenable: S,
          builder: (c, _) => ListView(padding: const EdgeInsets.all(16), children: kids(c)),
        ),
      );
}

void open(BuildContext c, Widget w) => Navigator.push(c, MaterialPageRoute(builder: (_) => w));

Widget avatarWidget() {
  if (S.avatar.isNotEmpty && File(S.avatar).existsSync()) {
    return Image.file(File(S.avatar), fit: BoxFit.cover, width: double.infinity, height: double.infinity);
  }
  return Container(
    decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.3), colors: [Color(0xFF4B1A7A), Color(0xFF120A1C)])),
    child: const Center(child: Icon(Icons.face_3, size: 120, color: Color(0x88B44DFF))),
  );
}

Future<Uint8List?> pickBytes({bool camera = false}) async {
  final x = await ImagePicker().pickImage(source: camera ? ImageSource.camera : ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
  return x == null ? null : await x.readAsBytes();
}

Future<String?> pickAndStore(String name) async {
  final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1200, imageQuality: 88);
  if (x == null) return null;
  final d = await getApplicationDocumentsDirectory();
  final f = await File(x.path).copy('${d.path}/${name}_${DateTime.now().millisecondsSinceEpoch}.jpg');
  return f.path;
}

// ───────────────────────── shell ─────────────────────────
class Shell extends StatelessWidget {
  const Shell({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: S,
      builder: (context, _) {
        final wallOk = S.wall.isNotEmpty && File(S.wall).existsSync();
        return Stack(children: [
          Container(color: kBg),
          if (wallOk) Positioned.fill(child: Opacity(opacity: 0.18, child: Image.file(File(S.wall), fit: BoxFit.cover))),
          Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(children: [
              SafeArea(
                child: IndexedStack(index: S.tab, children: [
                  const HomeTab(),
                  const ChatTab(),
                  triggersTab(context),
                  settingsTab(context),
                ]),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: S.alert,
                builder: (c, v, _) => v == null ? const SizedBox.shrink() : guardOverlay(c, v),
              ),
            ]),
            bottomNavigationBar: navBar(context),
          ),
        ]);
      },
    );
  }

  Widget navBar(BuildContext context) {
    Widget item(IconData i, String l, int idx) => Expanded(
          child: InkWell(
            onTap: () => S.goTab(idx),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(i, color: S.tab == idx ? Color(S.orb) : kMut),
              Text(l, style: TextStyle(fontSize: 11, color: S.tab == idx ? Color(S.orb) : kMut)),
            ]),
          ),
        );
    final oc = S.listening ? const Color(0xFF00E5FF) : Color(S.orb);
    return Container(
      color: const Color(0xF007070B),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom, top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        item(Icons.home_outlined, 'Home', 0),
        item(Icons.chat_bubble_outline, 'Chat', 1),
        GestureDetector(
          onTap: () { S.goTab(0); S.listenOnce((t) => S.send(t)); },
          child: Container(
            width: 66, height: 66, margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: oc, width: 2), color: const Color(0xFF0A0A10)),
            child: ClipOval(child: ParticleOrb(size: 56, color: oc, active: S.listening)),
          ),
        ),
        item(Icons.bolt, 'Triggers', 2),
        item(Icons.settings_outlined, 'Settings', 3),
      ]),
    );
  }

  Widget guardOverlay(BuildContext c, String line) => Positioned.fill(
        child: Container(
          color: const Color(0xFFB00018),
          padding: const EdgeInsets.all(30),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.warning_amber_rounded, size: 90),
            const Text('Phone ko haath mat lagao!', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            Text(line, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
            const SizedBox(height: 30),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: () async {
                if (S.pin.isNotEmpty) {
                  final v = await askText(c, 'PIN daalo', pw: true);
                  if (v != S.pin) { toast('Galat PIN'); return; }
                }
                S.disarm();
              },
              child: const Text('Owner? Unlock'),
            ),
          ]),
        ),
      );
}

// ───────────────────────── Home ─────────────────────────
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});
  @override
  State<HomeTab> createState() => _HomeS();
}

class _HomeS extends State<HomeTab> {
  final ctl = TextEditingController();

  @override
  void dispose() { ctl.dispose(); super.dispose(); }

  Widget qa(IconData ic, String label, Color col, VoidCallback f) => SizedBox(
        width: 62,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: f,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 58, height: 58,
              decoration: BoxDecoration(color: const Color(0xFF14141E), borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
              child: Icon(ic, color: col, size: 26),
            ),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Color(0xFFD0D0DC))),
          ]),
        ),
      );

  Future<void> _launch(String nm, List<String> urls) async {
    for (final u in urls) {
      if (await openLink(u)) return;
    }
    toast('$nm nahi khul paya');
  }

  void _more() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 14, runSpacing: 14, children: [
            qa(Icons.map_outlined, 'Maps', const Color(0xFF4CAF50), () { Navigator.pop(c); _launch('Maps', ['https://maps.google.com']); }),
            qa(Icons.photo_camera_outlined, 'Camera', kLav, () async { Navigator.pop(c); if (!await openCamera()) toast('Camera nahi khula'); }),
            qa(Icons.psychology_outlined, 'Memory', kLav, () { Navigator.pop(c); open(context, pgMemory()); }),
            qa(Icons.shield_outlined, 'Touch Guard', const Color(0xFFFF6B6B), () { Navigator.pop(c); S.goTab(2); }),
            qa(Icons.settings_outlined, 'Settings', kMut, () { Navigator.pop(c); S.goTab(3); }),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = (S.provider == 'gemini' ? S.kGemini : S.kGrok).trim().isNotEmpty;
    final lastAi = S.mem.where((m) => m.role == 'assistant').toList();
    final oc = Color(S.orb);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
      // header
      Row(children: [
        IconButton(
          style: IconButton.styleFrom(side: const BorderSide(color: kLine)),
          onPressed: () => S.goTab(3),
          icon: const Icon(Icons.menu),
        ),
        const Expanded(
          child: Column(children: [
            Text('MYRA', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 4)),
            Text('Your Intelligent AI Assistant', style: TextStyle(color: kMut, fontSize: 10)),
          ]),
        ),
        IconButton(
          style: IconButton.styleFrom(side: const BorderSide(color: kLine)),
          onPressed: () => toast('Koi nayi notification nahi'),
          icon: const Icon(Icons.notifications_none),
        ),
      ]),
      const SizedBox(height: 14),
      // hello card
      Container(
        height: 190,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1B0F2E), Color(0xFF0B0812)]),
          border: Border.all(color: kLine),
        ),
        child: Row(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 0, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('Hello, ${S.name}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1)),
                const SizedBox(height: 6),
                const Text("I'm MYRA, here to help you anytime!", style: TextStyle(color: Color(0xFFD0D0DC), fontSize: 13)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: (ready ? const Color(0xFF1B5E20) : const Color(0xFF5E3B00)).withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: ready ? const Color(0xFF4CAF50) : const Color(0xFFFFA726)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle, size: 9, color: ready ? const Color(0xFF4CAF50) : const Color(0xFFFFA726)),
                    const SizedBox(width: 6),
                    Text(ready ? 'Online • Ready' : 'API key daalo', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ]),
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.only(topRight: Radius.circular(24), bottomRight: Radius.circular(24)),
            child: SizedBox(width: 130, height: 190, child: avatarWidget()),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      // ask bar
      Container(
        padding: const EdgeInsets.only(left: 14, right: 6),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(30), border: Border.all(color: oc.withOpacity(0.7))),
        child: Row(children: [
          Icon(Icons.auto_awesome, color: oc, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: ctl,
              textInputAction: TextInputAction.send,
              onSubmitted: (v) { ctl.clear(); S.send(v); },
              decoration: const InputDecoration(hintText: 'Ask me anything...', border: InputBorder.none, isDense: true),
            ),
          ),
          IconButton(
            onPressed: () async {
              final b = await pickBytes();
              if (b != null) { S.send(ctl.text.isEmpty ? 'Is image me kya hai? Samjhao.' : ctl.text, img: b); ctl.clear(); }
            },
            icon: const Icon(Icons.photo_camera_outlined, size: 22),
          ),
          IconButton(
            onPressed: () => S.listenOnce((t) => S.send(t)),
            icon: Icon(Icons.mic, color: S.listening ? const Color(0xFF00E5FF) : Colors.white),
          ),
        ]),
      ),
      const SizedBox(height: 18),
      // quick actions
      Row(children: [
        const Text('Quick Actions', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const Spacer(),
        GestureDetector(onTap: () => toast('Edit option agle version me aayega'), child: Text('Edit', style: TextStyle(color: oc, fontSize: 13))),
      ]),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        qa(Icons.chat_bubble_outline, 'AI Chat', kLav, () => S.goTab(1)),
        qa(Icons.mic_none, 'Voice Talk', kLav, () => S.listenOnce((t) => S.send(t))),
        qa(Icons.desktop_windows_outlined, 'PC Connect', kLav, () => _launch('Remote Desktop', ['https://remotedesktop.google.com/access'])),
        qa(Icons.smart_toy_outlined, 'Automation', kLav, () async {
          final g = await askText(context, 'MYRA ko goal batao');
          if (g != null && g.trim().isNotEmpty) { S.mode = 'mission'; S.send('Mission: $g'); }
        }),
        qa(Icons.center_focus_strong_outlined, 'Smart Scan', kLav, () async {
          final b = await pickBytes(camera: true);
          if (b != null) S.send('Is image ko detail me describe karo aur batao ye kya hai.', img: b);
        }),
      ]),
      const SizedBox(height: 14),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        qa(Icons.smart_display, 'YouTube', const Color(0xFFFF1744), () => _launch('YouTube', ['vnd.youtube://', 'https://www.youtube.com'])),
        qa(Icons.chat, 'WhatsApp', const Color(0xFF25D366), () => _launch('WhatsApp', ['whatsapp://send', 'https://wa.me/'])),
        qa(Icons.call, 'Calls', const Color(0xFF2196F3), () async { if (!await openDialer()) toast('Dialer nahi khula'); }),
        qa(Icons.music_note, 'Music', const Color(0xFFFF1744), () => _launch('Music', ['https://music.youtube.com'])),
        qa(Icons.apps, 'More', kLav, _more),
      ]),
      const SizedBox(height: 18),
      // continue chat card
      card(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome, color: oc, size: 18),
            const SizedBox(width: 8),
            const Text('AI Chat', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const Spacer(),
            const Icon(Icons.chevron_right, color: kMut),
          ]),
          const SizedBox(height: 4),
          Text(
            lastAi.isEmpty ? 'Naya chat shuru karo' : 'Continue your last conversation',
            style: const TextStyle(color: kMut, fontSize: 12),
          ),
          if (lastAi.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(lastAi.last.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ],
        ]),
        border: oc.withOpacity(0.6),
        onTap: () => S.goTab(1),
      ),
      card(Row(children: [const Text('🎓', style: TextStyle(fontSize: 24)), const SizedBox(width: 12), Expanded(child: titled('English Teacher AI', 'Learn English · Speak · Improve · Interview'))]),
          onTap: () { S.mode = 'teacher'; S.send('Hello teacher, aaj ka English practice shuru karte hain.'); }),
      Row(children: [
        Expanded(
          child: card(titled('✨ Deep Research', 'Kisi topic pe gehri research'), onTap: () async {
            final t = await askText(context, 'Kis topic par research?');
            if (t != null && t.trim().isNotEmpty) S.send('Deep research karo is topic par: $t. Key points, pros/cons aur next steps do.');
          }),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: card(titled('🖼 Image Search', 'Photo bhejo, MYRA samjhayegi'), onTap: () async {
            final b = await pickBytes();
            if (b != null) S.send('Is image ko detail me describe karo aur batao ye kya hai.', img: b);
          }),
        ),
      ]),
    ]);
  }
}

// ───────────────────────── Chat ─────────────────────────
class ChatTab extends StatefulWidget {
  const ChatTab({super.key});
  @override
  State<ChatTab> createState() => _ChatS();
}

class _ChatS extends State<ChatTab> {
  final ctl = TextEditingController();
  Uint8List? img;

  Widget bubble(String t, bool me, {Uint8List? image}) => Align(
        alignment: me ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: me ? const Color(0xFF2A1445) : const Color(0xFF181822),
            borderRadius: BorderRadius.circular(16),
            border: me ? null : Border.all(color: kLine),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (image != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(image))),
            Text(t, style: const TextStyle(fontSize: 14.5, height: 1.4)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final items = S.mem.reversed.toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
        child: Row(children: [
          const Text('Chat', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const Spacer(),
          TextButton(onPressed: () => open(context, pgMemory()), child: const Text('🧠 Memory')),
          TextButton(
            onPressed: () { S.mem.clear(); S.saveMem(); S.notifyListeners(); },
            child: const Text('Clear'),
          ),
        ]),
      ),
      Expanded(
        child: items.isEmpty && !S.busy
            ? const Center(child: Text('Kuch bolo ya likho. MYRA sun rahi hai.', style: TextStyle(color: kMut)))
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length + (S.busy ? 1 : 0),
                itemBuilder: (c, i) {
                  if (S.busy) {
                    if (i == 0) return bubble('...', false);
                    i--;
                  }
                  final m = items[i];
                  return bubble(m.text, m.role == 'user', image: m.img);
                },
              ),
      ),
      if (img != null)
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(img!, height: 60)), IconButton(onPressed: () => setState(() => img = null), icon: const Icon(Icons.close))])),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: ctl,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(hintText: 'Message MYRA...', filled: true, fillColor: kCard, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
          IconButton(onPressed: () async { final b = await pickBytes(); if (b != null) setState(() => img = b); }, icon: const Icon(Icons.photo_camera_outlined)),
          IconButton(onPressed: () => S.listenOnce((t) => S.send(t)), icon: Icon(Icons.mic, color: S.listening ? Color(S.orb) : null)),
          IconButton(onPressed: _send, icon: Icon(Icons.send, color: Color(S.orb))),
        ]),
      ),
    ]);
  }

  void _send() {
    final t = ctl.text;
    final i = img;
    ctl.clear();
    setState(() => img = null);
    S.send(t, img: i);
  }
}

// ───────────────────────── Triggers & Settings ─────────────────────────
Widget triggersTab(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Triggers', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      toggle('Wake Word', 'Boliye "Hey ${S.wakeWord}" (app chalu rehna chahiye)', S.wakeOn, (v) {
        S.wakeOn = v; S.save(); v ? S.startWake() : S.stopWake();
      }),
      toggle('Touch Guard', 'Phone uthane par alarm + photo + alert', S.tgArmed, (v) => v ? S.arm() : S.disarm()),
      toggle('Speak replies', 'MYRA jawab bolkar sunaye', S.speakOn, (v) { S.speakOn = v; S.save(); }),
      toggle('Floating Orb', 'App se bahar (YouTube wagairah par) bhi orb dikhe, tap karke bolo', S.orbOn, (v) {
        S.orbOn = v; S.save(); if (v) { S.initOrb(); S.startOrb(ask: true); } else { S.stopOrb(); }
      }),
      sec('MODE'),
      Wrap(spacing: 8, children: [
        chip('Normal', S.mode == 'normal', () { S.mode = 'normal'; S.notifyListeners(); }),
        chip('English Teacher', S.mode == 'teacher', () { S.mode = 'teacher'; S.notifyListeners(); }),
        chip('Mission', S.mode == 'mission', () { S.mode = 'mission'; S.notifyListeners(); }),
      ]),
      sec('AI PROVIDER'),
      Wrap(spacing: 8, children: [
        chip('Gemini', S.provider == 'gemini', () { S.provider = 'gemini'; S.save(); }),
        chip('Grok', S.provider == 'grok', () { S.provider = 'grok'; S.save(); }),
      ]),
    ]);

Widget settingsTab(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Settings', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      sec('PROFILE & ACCOUNT'),
      tile('👤', 'User Profile', 'Naam aur MYRA ki photo', () => open(context, pgProfile())),
      sec('VOICE & PERSONALITY'),
      tile('🎚', 'Voice & AI Models', 'Voice persona, Gemini / Grok, ElevenLabs', () => open(context, pgVoice())),
      tile('🗣', 'Wake Word', 'Customize how you start MYRA', () => open(context, pgWake())),
      tile('🎨', 'Orb Customization', 'Orb ka color', () => open(context, pgOrb())),
      sec('CORE INTERACTION'),
      tile('📇', 'Contacts', 'Call / WhatsApp ke liye naam aur number', () => open(context, pgContacts())),
      tile('🧠', 'MYRA Memory', 'Everything MYRA remembers, day by day', () => open(context, pgMemory())),
      tile('🌐', 'Language', 'Current: ${S.lang}', () => open(context, pgLang())),
      toggle('Haptic Feedback', 'Somatic vibrations', S.haptic, (v) { S.haptic = v; S.save(); }),
      sec('SECURITY & PRIVACY'),
      tile('🛡', 'Touch Guard', 'Phone ko haath lagane par warning', () => open(context, pgTouchGuard())),
      tile('🔐', 'MYRA Security', 'App PIN', () => open(context, pgSecurity())),
      tile('📋', 'Permissions', 'Mic, camera, location, notifications', () => openAppSettings()),
      sec('INTELLIGENCE & AUTOMATION'),
      tile('☁', 'API & Cloud Settings', 'Gemini, Grok, ElevenLabs keys', () => open(context, pgApi())),
      sec('ADVANCED'),
      tile('🏠', 'Set MYRA as Home Launcher', 'Replace your home screen with MYRA', () => open(context, pgLauncher())),
      tile('🎙', 'Set MYRA as Digital Assistant', 'Default assistant settings kholo', () async {
        try { await AndroidIntent(action: 'android.settings.VOICE_INPUT_SETTINGS').launch(); } catch (_) { toast('Settings nahi khuli'); }
      }),
    ]);

// ───────────────────────── Sub pages ─────────────────────────
Widget pgProfile() => Pg('User Profile', (c) => [
      Field('Aapka naam', S.name, (v) { S.name = v.trim().isEmpty ? 'Boss' : v.trim(); S.save(notify: false); }),
      sec('MYRA KI PHOTO (avatar)'),
      SizedBox(height: 240, child: ClipRRect(borderRadius: BorderRadius.circular(20), child: avatarWidget())),
      btn('Image lagao', () async { final p = await pickAndStore('avatar'); if (p != null) { S.avatar = p; S.save(); } }),
      btn('Hatao', () { S.avatar = ''; S.save(); }, ghost: true),
      sec('WALLPAPER'),
      btn('Wallpaper lagao', () async { final p = await pickAndStore('wall'); if (p != null) { S.wall = p; S.save(); } }),
      btn('Wallpaper hatao', () { S.wall = ''; S.save(); }, ghost: true),
    ]);

Widget pgVoice() => Pg('Voice & AI Models', (c) => [
      sec('VOICE PERSONA'),
      for (final e in personas.entries)
        card(
          Row(children: [
            Text(e.key == 'robot' ? '🤖' : '👧', style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(child: titled(e.value.label, e.value.desc)),
            Icon(S.persona == e.key ? Icons.radio_button_checked : Icons.radio_button_off, color: Color(S.orb)),
          ]),
          border: S.persona == e.key ? Color(S.orb) : null,
          onTap: () { S.persona = e.key; S.save(); },
        ),
      btn('▶ Voice test karo', () => S.speak(S.persona == 'robot' ? 'Systems online, boss. Aapki awaaz sunkar mera processor tez chalne laga hai.' : 'Heyy, kaisa chal raha hai sab? Main yahin hu, bolo kya karna hai.', force: true), ghost: true),
      sec('VOICE ENGINE'),
      Wrap(spacing: 8, children: [
        chip('Phone voice (free)', S.tts == 'device', () { S.tts = 'device'; S.save(); }),
        chip('ElevenLabs', S.tts == 'eleven', () { S.tts = 'eleven'; S.save(); }),
      ]),
      const SizedBox(height: 10),
      Field('ElevenLabs Voice ID - Robotic Girlfriend', S.vidRobot, (v) { S.vidRobot = v.trim(); S.save(notify: false); }),
      Field('ElevenLabs Voice ID - Casual Girl', S.vidCasual, (v) { S.vidCasual = v.trim(); S.save(notify: false); }),
      sec('AI MODEL'),
      Wrap(spacing: 8, children: [
        chip('Gemini', S.provider == 'gemini', () { S.provider = 'gemini'; S.save(); }),
        chip('Grok', S.provider == 'grok', () { S.provider = 'grok'; S.save(); }),
      ]),
      const SizedBox(height: 10),
      Field('Gemini model', S.mGemini, (v) { S.mGemini = v.trim(); S.save(notify: false); }),
      Field('Gemini backup models (comma se) - limit khatam ho to ye chalenge', S.mGeminiFb, (v) { S.mGeminiFb = v.trim(); S.save(notify: false); }),
      Field('Grok model', S.mGrok, (v) { S.mGrok = v.trim(); S.save(notify: false); }),
    ]);

Widget pgContacts() => Pg('Contacts', (c) => [
      const Text('Yaha naam + number save karo. Phir bolo: "Rahul ko call karo" ya "Rahul ko WhatsApp karo ki main late hu". Naya naam bologi to MYRA khud number puchh legi.', style: TextStyle(color: kMut, fontSize: 13)),
      const SizedBox(height: 12),
      for (final e in S.contacts.entries)
        card(Row(children: [
          Expanded(child: titled(e.key, e.value)),
          InkWell(onTap: () { S.contacts.remove(e.key); S.save(); }, child: const Icon(Icons.delete_outline, color: kMut)),
        ])),
      sec('NAYA CONTACT'),
      Field('Naam (jaise Shaktinath)', '', (v) => _cn = v, key: ValueKey('n${S.contacts.length}')),
      Field('Number (jaise 9876543210)', '', (v) => _cp = v, kt: TextInputType.phone, key: ValueKey('p${S.contacts.length}')),
      btn('Save', () {
        if (_cn.trim().isEmpty || _cp.replaceAll(RegExp(r'\D'), '').length < 10) { toast('Naam aur 10 digit number daalo'); return; }
        S.contacts[_cn.trim()] = _cp.trim();
        _cn = ''; _cp = '';
        S.save();
        toast('Save ho gaya');
      }),
    ]);

Widget pgApi() => Pg('API & Cloud Settings', (c) => [
      Field('Gemini API key(s) - kai keys ho to comma se alag karo', S.kGemini, (v) { S.kGemini = v.trim(); S.save(notify: false); }, obscure: true),
      const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: Text('Free limit khatam ho to MYRA apne aap agli key / backup model par chali jaati hai. Alag Google accounts ki keys (aistudio.google.com/apikey) jodne se zyada chalega.', style: TextStyle(color: kMut, fontSize: 12)),
      ),
      Field('Grok / xAI API key (console.x.ai)', S.kGrok, (v) { S.kGrok = v.trim(); S.save(notify: false); }, obscure: true),
      Field('ElevenLabs API key', S.kEleven, (v) { S.kEleven = v.trim(); S.elevenDown = false; S.save(notify: false); }, obscure: true),
      Field('Picovoice AccessKey (optional, abhi use nahi hoti)', S.kPico, (v) { S.kPico = v.trim(); S.save(notify: false); }, obscure: true),
      btn('Test AI connection', () { S.mem.clear(); S.send('Bas "ok" bolo.'); }),
      const Text('Keys sirf is phone me save hoti hain. Kisi ko share mat karo.', style: TextStyle(color: kMut, fontSize: 12)),
    ]);

Widget pgWake() => Pg('Wake Word', (c) => [
      toggle('Wake Word', S.wakeOn ? 'Listening (Android speech engine)' : 'Off - not running', S.wakeOn, (v) { S.wakeOn = v; S.save(); v ? S.startWake() : S.stopWake(); }),
      Field('Custom Wake Word (sirf naam, jaise Myra)', S.wakeWord, (v) { S.wakeWord = v.replaceAll(RegExp(r'^(hey|wake up)\s+', caseSensitive: false), '').trim(); S.save(notify: false); }),
      Text('Bolo "Hey ${S.wakeWord}". Ek hi unique naam sabse accha chalta hai.', style: const TextStyle(color: kMut, fontSize: 12)),
      sec('SENSITIVITY'),
      Slider(value: S.wakeSens, min: 0.3, max: 1, activeColor: Color(S.orb), onChanged: (v) { S.wakeSens = v; S.save(); }),
      btn('Test Microphone', () => S.listenOnce((t) => toast('Suna: $t'))),
      const Text('Note: Android speech service use hota hai, isliye app khula/recent me chalu hona chahiye aur beech-beech me system beep aa sakta hai.', style: TextStyle(color: kMut, fontSize: 12)),
    ]);

Widget pgOrb() => Pg('Orb Customization', (c) => [
      Center(child: ParticleOrb(size: 150, color: Color(S.orb), active: true)),
      const SizedBox(height: 20),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final col in [0xFFB44DFF, 0xFFE8182F, 0xFF00E5FF, 0xFF39FF14, 0xFFFF9A1A])
          GestureDetector(onTap: () { S.orb = col; S.save(); }, child: CircleAvatar(radius: 24, backgroundColor: Color(col), child: S.orb == col ? const Icon(Icons.check, color: Colors.black) : null)),
      ]),
    ]);

Widget pgLang() => Pg('Language', (c) => [
      for (final l in const [['hi-IN', 'Hindi'], ['en-IN', 'English (India)'], ['en-US', 'English (US)']])
        card(Row(children: [Expanded(child: Text(l[1], style: const TextStyle(fontWeight: FontWeight.w700))), Icon(S.lang == l[0] ? Icons.radio_button_checked : Icons.radio_button_off, color: Color(S.orb))]), onTap: () { S.lang = l[0]; S.save(); }),
    ]);

Widget pgMemory() => Pg('MYRA Memory', (c) {
      final days = <String, List<Mem>>{};
      for (final m in S.mem.where((m) => m.role != 'sys')) { days.putIfAbsent(dayKey(m.ts), () => []).add(m); }
      final keys = days.keys.toList().reversed.toList();
      String memText = '';
      return [
        if (keys.isEmpty) const Text('Abhi koi memory nahi. Baat shuru karo.', style: TextStyle(color: kMut)),
        for (final k in keys)
          tile('📅', k == dayKey(DateTime.now().millisecondsSinceEpoch) ? 'Today' : k, '${days[k]!.length} memories', () => open(c, pgDay(k))),
        sec('KUCH YAAD RAKHWAO'),
        Field('Jaise: mera birthday 5 June hai', '', (v) => memText = v),
        btn('Yaad rakho', () {
          if (memText.trim().isEmpty) return;
          final t = DateTime.now().millisecondsSinceEpoch;
          S.mem.add(Mem(t, t, 'user', 'Yaad rakho: $memText'));
          S.mem.add(Mem(t + 1, t, 'assistant', 'Theek hai, yaad rakh liya: $memText'));
          S.saveMem();
          S.notifyListeners();
          toast('Yaad rakh liya');
        }),
        btn('Saari memory delete karo', () { S.mem.clear(); S.saveMem(); S.notifyListeners(); }, ghost: true),
      ];
    });

Widget pgDay(String k) => Pg(k, (c) => [
      for (final m in S.mem.where((m) => dayKey(m.ts) == k && m.role != 'sys'))
        card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(m.role == 'user' ? 'You said' : 'assistant', style: TextStyle(color: Color(S.orb), fontSize: 12)),
            const Spacer(),
            InkWell(onTap: () { S.mem.remove(m); S.saveMem(); S.notifyListeners(); }, child: const Icon(Icons.delete_outline, size: 20, color: kMut)),
          ]),
          const SizedBox(height: 6),
          Text(m.text),
        ])),
    ]);

Widget pgSecurity() => Pg('MYRA Security', (c) => [
      Field('App PIN (Touch Guard unlock ke liye bhi)', S.pin, (v) { S.pin = v.trim(); S.save(notify: false); }, obscure: true, kt: TextInputType.number),
      const Text('Biometric aur Voice Authentication abhi is version me nahi hain.', style: TextStyle(color: kMut, fontSize: 12)),
    ]);

Widget pgTouchGuard() => Pg('Touch Guard', (c) => [
      const Text('Phone chhodne se pehle arm karo. Koi utha kar chhuega to MYRA zor se warning degi, phir aapko alert bhejegi aur photo legi.', style: TextStyle(color: kMut, fontSize: 13)),
      const SizedBox(height: 12),
      card(
        Row(children: [
          Expanded(child: titled('Touch Guard: ${S.tgArmed ? 'Armed' : 'Off'}', S.tgArmed ? 'MYRA unauthorized device interaction dekh rahi hai.' : 'Device interaction monitored nahi hai.')),
          Switch(value: S.tgArmed, activeColor: Color(S.orb), onChanged: (v) => v ? S.arm() : S.disarm()),
        ]),
        border: S.tgArmed ? Color(S.orb) : null,
      ),
      sec('SENSITIVITY'),
      Wrap(spacing: 8, children: [for (final s in ['Low', 'Medium', 'High']) chip(s, S.tgSens == s, () { S.tgSens = s; S.save(); })]),
      sec('WARNING VOLUME'),
      Slider(value: S.tgVol, min: 0.1, max: 1, label: '${(S.tgVol * 100).round()}%', divisions: 9, activeColor: Color(S.orb), onChanged: (v) { S.tgVol = v; S.save(); }),
      sec('WARNING MODES'),
      toggle('🔊 Voice Alert', 'MYRA warning lines bolkar sunati hai', S.tgVoice, (v) { S.tgVoice = v; S.save(); }),
      toggle('📳 Vibration', 'Har warning stage par vibrate', S.tgVib, (v) { S.tgVib = v; S.save(); }),
      toggle('🔔 Siren / Alarm', 'Pehli warning par tez alarm', S.tgSiren, (v) { S.tgSiren = v; S.save(); }),
      toggle('📱 Full-Screen Warning', 'Interaction jaari rahe to full-screen alert', S.tgFull, (v) { S.tgFull = v; S.save(); }),
      sec('NOTIFY YOU (OPTIONAL)'),
      toggle('Notify owner', 'WhatsApp message (location ke saath) is number par khulega', S.tgNotify, (v) { S.tgNotify = v; S.save(); }),
      Field('WhatsApp number (country code ke saath, jaise 919876543210)', S.tgPhone, (v) { S.tgPhone = v.trim(); S.save(notify: false); }, kt: TextInputType.phone),
      toggle('Take intruder photo', 'Front camera se photo leke app me save karta hai', S.tgPhoto, (v) { S.tgPhoto = v; S.save(); }),
      btn('Test warning', () { S.stage = 1; S.trigger(); S.stage = 1; }, ghost: true),
      if (S.photos.isNotEmpty) sec('CAPTURED PHOTOS'),
      for (final p in S.photos) if (File(p).existsSync()) Padding(padding: const EdgeInsets.only(bottom: 10), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(p)))),
    ]);

Widget pgLauncher() => Pg('Launcher', (c) {
      final h = DateTime.now().hour;
      return [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 340,
            child: Stack(children: [
              Positioned.fill(child: Opacity(opacity: 0.55, child: avatarWidget())),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(h < 12 ? 'GOOD MORNING' : h < 18 ? 'GOOD AFTERNOON' : 'GOOD NIGHT', style: TextStyle(color: Color(S.orb), fontSize: 12)),
                  Text(S.name.toUpperCase(), style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800)),
                  Text("I'M ALWAYS WITH YOU", style: TextStyle(color: Color(S.orb), fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
        sec('THEME'),
        for (final t in const [['purple', 'Violet Pulse', 0xFFB44DFF], ['crimson', 'Crimson Core', 0xFFE8182F], ['cyan', 'Cyan Pulse', 0xFF00E5FF], ['matrix', 'Neon Matrix', 0xFF39FF14]])
          card(Row(children: [CircleAvatar(radius: 14, backgroundColor: Color(t[2] as int)), const SizedBox(width: 12), Text('${t[1]}${S.theme == t[0] ? ' (current)' : ''}', style: const TextStyle(fontWeight: FontWeight.w700))]),
              onTap: () { S.theme = t[0] as String; S.orb = t[2] as int; S.save(); }),
        sec('DEFAULT HOME APP'),
        btn('Set MYRA as Home', () async {
          try { await AndroidIntent(action: 'android.settings.HOME_SETTINGS').launch(); } catch (_) { toast('Settings > Apps > Default apps > Home app me jao'); }
        }),
        const Text('Is version me home screen par MYRA ka basic launcher screen khulta hai. Animated app wheel / app list agle version me aayega.', style: TextStyle(color: kMut, fontSize: 12)),
      ];
    });
