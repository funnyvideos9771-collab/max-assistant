import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'services/ai_service.dart';
import 'services/tts_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaxAssistantApp());
}

class MaxAssistantApp extends StatelessWidget {
  const MaxAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
  static const platform = MethodChannel('com.max.assistant/telecom');
  
  final stt.SpeechToText _speech = stt.SpeechToText();
  final AIService _aiService = AIService();
  final TTSService _ttsService = TTSService();

  bool _isListening = false;
  String _spokenText = "Bolne ke liye mic icon par tap karein...";
  String _aiResponse = "MAX System Online";

  @override
  void initState() {
    super.initState();
    _getPermissions();
  }

  Future<void> _getPermissions() async {
    await [
      Permission.microphone,
      Permission.phone,
    ].request();
  }

  void _listen() async {
    if (!_isListening) {
      bool available = await _speech.initialize();
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) {
            setState(() => _spokenText = val.recognizedWords);
            if (val.finalResult) {
              setState(() => _isListening = false);
              _processCommand(val.recognizedWords);
            }
          },
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  Future<void> _processCommand(String text) async {
    String query = text.toLowerCase();

    // 1. Phone Call & Speaker Command
    if (query.contains("phone utha") || query.contains("call answer") || query.contains("speaker")) {
      await _ttsService.speak("Call receive karke speaker par daal raha hu.");
      try {
        await platform.invokeMethod('answerCallAndSpeaker');
      } catch (e) {
        await _ttsService.speak("System permission missing hai.");
      }
    } 
    // 2. Intelligent AI Answer (Gemini API)
    else {
      String reply = await _aiService.askGemini(text);
      setState(() => _aiResponse = reply);
      await _ttsService.speak(reply);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("MAX VOICE ASSISTANT"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            GestureDetector(
              onTap: _listen,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isListening ? Colors.redAccent : Colors.cyan,
                  boxShadow: [
                    BoxShadow(
                      color: _isListening ? Colors.redAccent.withOpacity(0.5) : Colors.cyan.withOpacity(0.3),
                      blurRadius: 25,
                      spreadRadius: 10,
                    )
                  ],
                ),
                child: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  size: 70,
                  color: Colors.black,
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              _spokenText,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, color: Colors.white70),
            ),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _aiResponse,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.cyanAccent),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
