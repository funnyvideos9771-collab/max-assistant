import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaxAssistantApp());
}

class MaxAssistantApp extends StatelessWidget {
  const MaxAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Max AI Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;
  bool _isListening = false;
  String _statusText = "Tap mic to talk with Max";
  String _userSpeech = "";
  String _aiResponse = "";
  bool _isLoading = false;

  // Apni Gemini API Key yahan daal sakte hain (Agar nahi hai toh test message bolega)
  final String _geminiApiKey = "YOUR_GEMINI_API_KEY_HERE";

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
    _initTts();
  }

  void _initTts() async {
    await _flutterTts.setLanguage("hi-IN");
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _listen() async {
    if (!_isListening) {
      var status = await Permission.microphone.request();
      if (status.isGranted) {
        bool available = await _speech.initialize(
          onStatus: (val) {
            if (val == 'done' || val == 'notListening') {
              setState(() => _isListening = false);
              if (_userSpeech.isNotEmpty) {
                _getGeminiResponse(_userSpeech);
              }
            }
          },
          onError: (val) {
            setState(() {
              _isListening = false;
              _statusText = "Aawaz nahi sun paya, dobara try karein.";
            });
          },
        );

        if (available) {
          setState(() {
            _isListening = true;
            _statusText = "Listening... Bolna shuru karein";
            _userSpeech = "";
            _aiResponse = "";
          });
          _speech.listen(
            onResult: (val) {
              setState(() {
                _userSpeech = val.recognizedWords;
              });
            },
          );
        }
      } else {
        setState(() => _statusText = "Microphone permission zaroori hai!");
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  Future<void> _getGeminiResponse(String prompt) async {
    setState(() {
      _isLoading = true;
      _statusText = "Soch raha hu...";
    });

    if (_geminiApiKey == "YOUR_GEMINI_API_KEY_HERE" || _geminiApiKey.isEmpty) {
      String fallback = "Aapne bola: '$prompt'. Main aapki baat sun sakta hu!";
      _speakResponse(fallback);
      return;
    }

    try {
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_geminiApiKey',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {"text": "You are Max, a helpful AI assistant. Answer concisely in friendly Hinglish: $prompt"}
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String text = data['candidates'][0]['content']['parts'][0]['text'];
        _speakResponse(text);
      } else {
        _speakResponse("Gemini API error. Kripya API Key check karein.");
      }
    } catch (e) {
      _speakResponse("Internet connection error.");
    }
  }

  Future<void> _speakResponse(String text) async {
    setState(() {
      _isLoading = false;
      _aiResponse = text;
      _statusText = "Tap mic to talk again";
    });
    await _flutterTts.speak(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("MAX AI ASSISTANT"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_userSpeech.isNotEmpty)
              Text(
                'Aapne Kaha: "$_userSpeech"',
                style: const TextStyle(fontSize: 16, color: Colors.cyanAccent),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 20),
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isListening
                    ? Colors.cyanAccent.withOpacity(0.2)
                    : Colors.blue.withOpacity(0.1),
                boxShadow: [
                  BoxShadow(
                    color: _isListening
                        ? Colors.cyanAccent.withOpacity(0.6)
                        : Colors.blueAccent.withOpacity(0.3),
                    blurRadius: 30,
                    spreadRadius: 10,
                  )
                ],
              ),
              child: Icon(
                _isLoading ? Icons.psychology : Icons.graphic_eq,
                size: 70,
                color: _isListening ? Colors.cyanAccent : Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 30),
            Text(
              _statusText,
              style: const TextStyle(fontSize: 18, color: Colors.white70),
            ),
            const SizedBox(height: 20),
            if (_aiResponse.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _aiResponse,
                  style: const TextStyle(fontSize: 16, color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 40),
            GestureDetector(
              onTap: _listen,
              child: CircleAvatar(
                radius: 35,
                backgroundColor: _isListening ? Colors.redAccent : Colors.cyan,
                child: Icon(
                  _isListening ? Icons.stop : Icons.mic,
                  color: Colors.black,
                  size: 35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
