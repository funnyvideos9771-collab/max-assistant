import 'dart:convert';
import 'package:http/http.dart' as http;

class AIService {
  // Yahan apni Gemini API Key daalein
  final String geminiApiKey = "YOUR_GEMINI_API_KEY_HERE";

  Future<String> askGemini(String prompt) async {
    try {
      final url = Uri.parse(
        '[https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey](https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey)',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {
                  "text": "Aapka naam Max hai. Aap ek smart voice assistant hain. User ke is sawal ka bilkul chhota, sateek aur natural Hindi/Hinglish me jawab dein: $prompt"
                }
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['candidates'][0]['content']['parts'][0]['text'] ?? "Main samajh nahi paya.";
      } else {
        return "Server Error: ${response.statusCode}";
      }
    } catch (e) {
      return "Internet connection check karein.";
    }
  }
}
