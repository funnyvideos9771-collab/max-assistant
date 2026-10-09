import 'package:android_intent_plus/android_intent.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';

import 'page_viewer.dart';

/// Actions Gemini can trigger on this phone (via function calling).
/// Messages and calls open the compose / dialer screen, so nothing is sent
/// without your final tap.
class PhoneTools {
  static Map<String, dynamic> _fn(
          String name, String desc, Map<String, dynamic> props,
          [List<String> required = const []]) =>
      {
        'name': name,
        'description': desc,
        'parameters': {
          'type': 'OBJECT',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        },
      };

  static Map<String, dynamic> _s(String d) => {'type': 'STRING', 'description': d};
  static Map<String, dynamic> _i(String d) => {'type': 'INTEGER', 'description': d};

  static final List<Map<String, dynamic>> declarations = [
    _fn('open_app',
        'Open an app: whatsapp, youtube, instagram, facebook, telegram, spotify, chrome, gmail, camera, settings, snapchat, twitter, netflix, phone, messages, maps.',
        {'app_name': _s('App name in English lowercase')}, ['app_name']),
    _fn('call_number', 'Open the dialer with a phone number ready to call.',
        {'phone_number': _s('Digits, with country code if known')},
        ['phone_number']),
    _fn('send_sms', 'Open the SMS composer with the message prefilled.', {
      'phone_number': _s('Recipient number'),
      'message': _s('Message text'),
    }, ['phone_number', 'message']),
    _fn('send_whatsapp',
        'Open WhatsApp with a prefilled message. Phone number needs country code, digits only (India = 91...). Leave empty to choose a contact.',
        {
          'phone_number': _s('Digits with country code, or empty'),
          'message': _s('Message text'),
        },
        ['message']),
    _fn('search_web', 'Search Google in the browser.',
        {'query': _s('Search query')}, ['query']),
    _fn('play_youtube', 'Search YouTube and open the results.',
        {'query': _s('Song or video to search')}, ['query']),
    _fn('open_maps', 'Search a place or start navigation in Google Maps.',
        {'place': _s('Place name or address')}, ['place']),
    _fn('set_alarm', 'Set an alarm using 24-hour time.', {
      'hour': _i('0-23'),
      'minute': _i('0-59'),
      'label': _s('Optional label'),
    }, ['hour', 'minute']),
    _fn('set_timer', 'Start a countdown timer.', {
      'seconds': _i('Duration in seconds'),
      'label': _s('Optional label'),
    }, ['seconds']),
    _fn('flashlight', 'Turn the flashlight on or off.',
        {'state': _s('"on" or "off"')}, ['state']),
    _fn('open_settings',
        'Open a settings page: wifi, bluetooth, display, or general.',
        {'page': _s('wifi, bluetooth, display or general')}, ['page']),
    _fn('create_website',
        'Design and build a complete website / landing page / portfolio and show it on screen. Pass a detailed design brief.',
        {
          'title': _s('Short page title'),
          'description': _s('Detailed brief: purpose, sections, style, colors, copy ideas'),
        },
        ['description']),
    _fn('create_map', 'Show a place on an interactive dark map on screen.',
        {'place': _s('Place name, city or address')}, ['place']),
    _fn('navigate', 'Start turn-by-turn navigation to a destination in Google Maps.',
        {'destination': _s('Destination')}, ['destination']),
    _fn('device_status', 'Get battery level, charging state and current time.',
        {}),
  ];

  static const Map<String, String> _appLinks = {
    'whatsapp': 'whatsapp://send',
    'youtube': 'vnd.youtube://',
    'instagram': 'instagram://app',
    'facebook': 'fb://feed',
    'telegram': 'tg://',
    'spotify': 'spotify://',
    'chrome': 'https://www.google.com',
    'browser': 'https://www.google.com',
    'gmail': 'mailto:',
    'snapchat': 'snapchat://',
    'twitter': 'twitter://',
    'x': 'twitter://',
    'netflix': 'nflx://www.netflix.com',
    'phone': 'tel:',
    'dialer': 'tel:',
    'messages': 'sms:',
    'sms': 'sms:',
    'maps': 'geo:0,0?q=',
  };

  static Future<Map<String, dynamic>> run(
      String name, Map<String, dynamic> a) async {
    try {
      switch (name) {
        case 'open_app':
          final app = _str(a, 'app_name').toLowerCase().trim();
          if (app == 'camera') {
            await const AndroidIntent(action: 'android.media.action.STILL_IMAGE_CAMERA').launch();
            return _ok('Camera opened');
          }
          if (app == 'settings') {
            await const AndroidIntent(action: 'android.settings.SETTINGS').launch();
            return _ok('Settings opened');
          }
          final link = _appLinks[app];
          if (link == null) return _fail('Unknown app: $app');
          return _open(link, 'Opened $app');
        case 'call_number':
          return _open('tel:${_digits(_str(a, 'phone_number'))}', 'Dialer opened');
        case 'send_sms':
          return _open(
              'sms:${_digits(_str(a, 'phone_number'))}?body=${Uri.encodeComponent(_str(a, 'message'))}',
              'SMS composer opened');
        case 'send_whatsapp':
          final num = _digits(_str(a, 'phone_number'));
          final text = Uri.encodeComponent(_str(a, 'message'));
          final url = num.isEmpty
              ? 'whatsapp://send?text=$text'
              : 'https://wa.me/$num?text=$text';
          return _open(url, 'WhatsApp opened with message ready');
        case 'search_web':
          return _open(
              'https://www.google.com/search?q=${Uri.encodeQueryComponent(_str(a, 'query'))}',
              'Search opened');
        case 'play_youtube':
          return _open(
              'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(_str(a, 'query'))}',
              'YouTube results opened');
        case 'open_maps':
          return _open('geo:0,0?q=${Uri.encodeComponent(_str(a, 'place'))}',
              'Maps opened');
        case 'set_alarm':
          await AndroidIntent(
            action: 'android.intent.action.SET_ALARM',
            arguments: <String, dynamic>{
              'android.intent.extra.alarm.HOUR': _int(a, 'hour'),
              'android.intent.extra.alarm.MINUTES': _int(a, 'minute'),
              'android.intent.extra.alarm.MESSAGE': _str(a, 'label'),
              'android.intent.extra.alarm.SKIP_UI': true,
            },
          ).launch();
          return _ok('Alarm set for ${_int(a, 'hour')}:${_int(a, 'minute').toString().padLeft(2, '0')}');
        case 'set_timer':
          await AndroidIntent(
            action: 'android.intent.action.SET_TIMER',
            arguments: <String, dynamic>{
              'android.intent.extra.alarm.LENGTH': _int(a, 'seconds'),
              'android.intent.extra.alarm.MESSAGE': _str(a, 'label'),
              'android.intent.extra.alarm.SKIP_UI': true,
            },
          ).launch();
          return _ok('Timer started for ${_int(a, 'seconds')} seconds');
        case 'flashlight':
          if (_str(a, 'state').toLowerCase() == 'on') {
            await TorchLight.enableTorch();
            return _ok('Flashlight on');
          }
          await TorchLight.disableTorch();
          return _ok('Flashlight off');
        case 'open_settings':
          const pages = {
            'wifi': 'android.settings.WIFI_SETTINGS',
            'bluetooth': 'android.settings.BLUETOOTH_SETTINGS',
            'display': 'android.settings.DISPLAY_SETTINGS',
          };
          final action = pages[_str(a, 'page').toLowerCase()] ?? 'android.settings.SETTINGS';
          await AndroidIntent(action: action).launch();
          return _ok('Settings opened');
        case 'device_status':
          final battery = Battery();
          final level = await battery.batteryLevel;
          final state = await battery.batteryState;
          return {
            'ok': true,
            'battery_percent': level,
            'charging_state': state.name,
            'time': DateTime.now().toString(),
          };
        case 'create_map':
          final place = _str(a, 'place');
          pageNotifier.value = GeneratedPage('Map: $place', buildMapHtml(place));
          return _ok('Map of $place is now shown on screen');
        case 'navigate':
          return _open(
              'google.navigation:q=${Uri.encodeComponent(_str(a, 'destination'))}',
              'Navigation started');
        default:
          return _fail('Unknown tool: $name');
      }
    } catch (e) {
      return _fail('Could not do that on this phone: $e');
    }
  }

  static Future<Map<String, dynamic>> _open(String url, String okMsg) async {
    final launched = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    return launched ? _ok(okMsg) : _fail('No app available to handle this');
  }

  static Map<String, dynamic> _ok(String m) => {'ok': true, 'message': m};
  static Map<String, dynamic> _fail(String m) => {'ok': false, 'error': m};
  static String _str(Map<String, dynamic> a, String k) => (a[k] ?? '').toString();
  static int _int(Map<String, dynamic> a, String k) =>
      int.tryParse((a[k] ?? '0').toString().split('.').first) ?? 0;
  static String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');
}
