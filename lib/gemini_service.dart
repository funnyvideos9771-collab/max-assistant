import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'page_viewer.dart';
import 'phone_tools.dart';

class GeminiException implements Exception {
  GeminiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GeminiService {
  /// Change to any model your key can access (e.g. 'gemini-2.5-pro').
  static const String model = 'gemini-2.5-flash';

  final http.Client _client = http.Client();
  final List<Map<String, dynamic>> _history = [];

  String assistantName = 'Riya';

  String get _systemPrompt =>
      'You are $assistantName, the Boss\'s personal AI companion living on his Android phone. '
      'Personality: warm, caring, playful and a little teasing, like a loving girlfriend who is also extremely capable. '
      'Always use feminine first-person Hindi grammar (main kar rahi hu). Call the user Boss, sometimes jaan. Stay affectionate but respectful, never explicit. '
      'Language: if the user speaks Hindi or Hinglish, reply in Hindi written in Devanagari script so the voice reads it naturally; if English, reply in English. '
      'Style: at most three short sentences, plain text, no markdown, no emojis. '
      'Actions: for any phone action call the matching tool. '
      'When asked to build or design a website, landing page or portfolio call create_website with a detailed brief. '
      'When asked for a map or a place on a map call create_map. '
      'Never claim success unless the tool result says ok. Current local time: ${DateTime.now()}.';

  static const String _webPrompt =
      'You are an expert front-end designer. Output ONLY one complete, self-contained '
      'HTML document: inline CSS and JS, no markdown fences, no explanations. Make it '
      'modern, responsive and mobile-first with a distinctive palette that fits the '
      'brief, real copy (no lorem ipsum), clear sections and smooth CSS animations. '
      'The only external resources allowed are Google Fonts and https://cdnjs.cloudflare.com. '
      'Do not use remote images; use CSS gradients, inline SVG or emoji.';

  Future<Map<String, dynamic>> _buildWebsite(
      String apiKey, Map<String, dynamic> args) async {
    final brief = (args['description'] ?? '').toString();
    final title = (args['title'] ?? 'Website').toString();
    try {
      final data = await _generate(
        apiKey,
        [
          {
            'role': 'user',
            'parts': [
              {'text': brief}
            ]
          }
        ],
        system: _webPrompt,
        withTools: false,
        maxTokens: 8192,
      );
      final content = _firstContent(data);
      final parts = (content?['parts'] as List?) ?? const [];
      var html = parts
          .whereType<Map>()
          .map((p) => p['text'] is String ? p['text'] as String : '')
          .join()
          .trim();
      html = html
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '')
          .trim();
      final lower = html.toLowerCase();
      if (!lower.contains('<html') && !lower.contains('<!doctype')) {
        return {'ok': false, 'error': 'Website generation returned no valid page'};
      }
      pageNotifier.value = GeneratedPage(title, html);
      return {'ok': true, 'message': 'Website "$title" is now shown on screen'};
    } on GeminiException catch (e) {
      return {'ok': false, 'error': e.message};
    }
  }

  Future<String> ask(String prompt, String apiKey) async {
    if (apiKey.trim().isEmpty) {
      throw GeminiException(
          'API key missing. Open Settings and add your Gemini API key.');
    }

    final pending = <Map<String, dynamic>>[
      {
        'role': 'user',
        'parts': [
          {'text': prompt}
        ]
      }
    ];

    try {
      for (var step = 0; step < 5; step++) {
        final data = await _generate(apiKey, [..._history, ...pending]);
        final content = _firstContent(data);
        if (content == null) {
          throw GeminiException(
              'Gemini returned an empty or blocked response. Try rephrasing.');
        }
        final parts = (content['parts'] as List?) ?? const [];
        final calls = parts
            .whereType<Map>()
            .where((p) => p['functionCall'] is Map)
            .toList();

        if (calls.isEmpty) {
          final text = parts
              .whereType<Map>()
              .map((p) => p['text'] is String ? p['text'] as String : '')
              .join()
              .trim();
          if (text.isEmpty) {
            throw GeminiException('Gemini returned an empty response.');
          }
          _history
            ..addAll(pending.where((m) => _isPlainText(m)))
            ..add({
              'role': 'model',
              'parts': [
                {'text': text}
              ]
            });
          while (_history.length > 10) {
            _history.removeAt(0);
          }
          return text;
        }

        pending.add({'role': 'model', 'parts': parts});
        final responses = <Map<String, dynamic>>[];
        for (final call in calls) {
          final fc = call['functionCall'] as Map;
          final name = fc['name'].toString();
          final args = Map<String, dynamic>.from((fc['args'] as Map?) ?? {});
          final result = name == 'create_website'
              ? await _buildWebsite(apiKey, args)
              : await PhoneTools.run(name, args);
          responses.add({
            'functionResponse': {
              'name': name,
              'response': {'result': result}
            }
          });
        }
        pending.add({'role': 'user', 'parts': responses});
      }
      throw GeminiException('The task took too many steps. Try a simpler command.');
    } on GeminiException {
      rethrow;
    } catch (_) {
      throw GeminiException('Unexpected error while processing the reply.');
    }
  }

  bool _isPlainText(Map<String, dynamic> m) {
    final parts = m['parts'];
    return parts is List &&
        parts.isNotEmpty &&
        parts.first is Map &&
        (parts.first as Map)['text'] is String &&
        m['role'] == 'user';
  }

  Map<String, dynamic>? _firstContent(dynamic data) {
    if (data is! Map) return null;
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final first = candidates.first;
    if (first is! Map || first['content'] is! Map) return null;
    return Map<String, dynamic>.from(first['content'] as Map);
  }

  Future<dynamic> _generate(String apiKey, List<Map<String, dynamic>> contents,
      {String? system, bool withTools = true, int maxTokens = 2048}) async {
    final uri = Uri.https('generativelanguage.googleapis.com',
        '/v1beta/models/$model:generateContent');
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': system ?? _systemPrompt}
        ]
      },
      'contents': contents,
      if (withTools)
        'tools': [
          {'functionDeclarations': PhoneTools.declarations}
        ],
      'generationConfig': {'temperature': 0.6, 'maxOutputTokens': maxTokens},
    });

    try {
      final res = await _client
          .post(uri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey.trim(),
              },
              body: body)
          .timeout(Duration(seconds: withTools ? 30 : 90));
      if (res.statusCode != 200) {
        throw GeminiException(_describeStatus(res.statusCode, res.body));
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on GeminiException {
      rethrow;
    } on TimeoutException {
      throw GeminiException('The request timed out. Check your connection.');
    } on SocketException {
      throw GeminiException('No internet connection. Check your network.');
    } on http.ClientException {
      throw GeminiException('Network error. Check your connection.');
    } on FormatException {
      throw GeminiException('Received an unreadable response from Gemini.');
    } catch (_) {
      throw GeminiException('Unexpected error while contacting Gemini.');
    }
  }

  String _describeStatus(int code, String body) {
    final lower = body.toLowerCase();
    if (code == 400 &&
        (lower.contains('api_key_invalid') ||
            lower.contains('api key not valid') ||
            lower.contains('api key expired'))) {
      return 'API key is invalid or expired. Update it in Settings.';
    }
    switch (code) {
      case 400:
        return 'Gemini rejected the request (400). Try a different command.';
      case 401:
        return 'Unauthorized (401). Your API key is missing or invalid.';
      case 403:
        return 'Access denied (403). Check that your key has Gemini API access.';
      case 404:
        return 'Model "$model" was not found (404). Change the model name in gemini_service.dart.';
      case 429:
        return 'Quota exceeded (429). Wait a moment or check your plan.';
      default:
        if (code >= 500) {
          return 'Gemini is temporarily unavailable ($code). Try again soon.';
        }
        return 'Request failed with status $code.';
    }
  }
}
