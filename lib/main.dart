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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("MAX VOICE ASSISTANT"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: const Center(
        child: Text("Max AI Ready"),
      ),
    );
  }
}
