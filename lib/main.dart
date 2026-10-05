          Future<void> _getAiResponse(String prompt) async {
            setState(() {
              _isLoading = true;
              _aiResponse = "Connecting with Jarvis AI...";
            });

            try {
              String activeKey = _geminiKey.isNotEmpty ? _geminiKey : _buildTimeGeminiKey;
              
              String addressing = _activeUserRole == "Boss" ? "Boss" : (_activeUserRole == "Madam" ? "Madam" : (_activeUserRole == "Mummy ji" ? "Mummy ji" : "Aditi"));
              String systemPrompt = "You are Jarvis (Max), an advanced AI assistant created for Sonu and Junu, with model name Jivani. Address current user respectfully as '$addressing'. Give precise, direct, technical, and smart responses for coding, general queries, and tasks.";
              
              // Naye AQ... format aur standard AIzaSy dono ke liye compatible headers aur endpoint setup
              Uri url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent');
              
              Map<String, String> headers = {'Content-Type': 'application/json'};
              
              // Agar key 'AQ.' se start hoti hai (OAuth/Auth token), toh Bearer token ya Authorization header use hoga
              if (activeKey.startsWith("AQ.")) {
                headers['Authorization'] = 'Bearer $activeKey';
              } else {
                // Purane format ke liye query parameter
                url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$activeKey');
              }
              
              final res = await http.post(
                url,
                headers: headers,
                body: jsonEncode({
                  "contents": [
                    {
                      "parts": [
                        {"text": "$systemPrompt\nQuery: $prompt"}
                      ]
                    }
                  ]
                }),
              );

              if (res.statusCode == 200) {
                final data = jsonDecode(res.body);
                String ans = data['candidates'][0]['content']['parts'][0]['text'].toString().trim();
                _speakAndShow(ans);
              } else {
                _speakAndShow("API Error (${res.statusCode}): Naye auth token ke sath request process karne mein issue aaya hai, Boss.");
              }
            } catch (e) {
              _speakAndShow("Network error while connecting to Gemini AI, $_activeUserRole.");
            }
          }
