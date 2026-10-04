import 'dart:convert';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

class TTSService {
  final FlutterTts _flutterTts = FlutterTts();
  
  // ElevenLabs API Key (Ultra Realistic Human Voice ke liye)
  final String elevenLabsKey = "YOUR_ELEVENLABS_API_KEY_HERE"; 
  final String voiceId = "21m00Tcm4TlvDq8ikWAM"; // Natural Voice

  TTSService() {
    _flutterTts.setLanguage("hi-IN");
    _flutterTts.setSpeechRate(0.5);
    _flutterTts.setPitch(1.0);
  }

  Future<void> speak(String text) async {
    if (elevenLabsKey != "YOUR_ELEVENLABS_API_KEY_HERE" && elevenLabsKey.isNotEmpty) {
      try {
        final response = await http.post(
          Uri.parse('[https://api.elevenlabs.io/v1/text-to-speech/$voiceId](https://api.elevenlabs.io/v1/text-to-speech/$voiceId)'),
          headers: {
            'xi-api-key': elevenLabsKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            "text": text,
            "voice_settings": {"stability": 0.5, "similarity_boost": 0.75}
          }),
        );
        
        if (response.statusCode != 200) {
          await _flutterTts.speak(text);
        }
      } catch (e) {
        await _flutterTts.speak(text);
      }
    } else {
      await _flutterTts.speak(text);
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }
}
