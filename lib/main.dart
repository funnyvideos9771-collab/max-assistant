import 'package:flutter/material.dart';

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
  bool isListening = false;
  String statusText = "Tap mic to talk with Max";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("MAX AI ASSISTANT"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isListening ? Colors.cyanAccent.withOpacity(0.2) : Colors.blue.withOpacity(0.1),
                boxShadow: [
                  BoxShadow(
                    color: isListening ? Colors.cyanAccent.withOpacity(0.6) : Colors.blueAccent.withOpacity(0.3),
                    blurRadius: 30,
                    spreadRadius: 10,
                  )
                ],
              ),
              child: Icon(
                Icons.graphic_eq,
                size: 80,
                color: isListening ? Colors.cyanAccent : Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 40),
            Text(
              statusText,
              style: const TextStyle(fontSize: 18, color: Colors.white70),
            ),
            const SizedBox(height: 60),
            GestureDetector(
              onTap: () {
                setState(() {
                  isListening = !isListening;
                  statusText = isListening ? "Listening..." : "Tap mic to talk with Max";
                });
              },
              child: CircleAvatar(
                radius: 35,
                backgroundColor: Colors.cyan,
                child: Icon(
                  isListening ? Icons.stop : Icons.mic,
                  color: Colors.black,
                  size: 35,
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
