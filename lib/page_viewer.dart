import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A page (website or map) the assistant generated and wants to show.
class GeneratedPage {
  GeneratedPage(this.title, this.html);
  final String title;
  final String html;
}

/// main.dart listens to this and opens the viewer when a page is set.
final ValueNotifier<GeneratedPage?> pageNotifier = ValueNotifier(null);

/// Dark Leaflet map. The place is geocoded inside the page with
/// OpenStreetMap Nominatim, so no API key is needed.
String buildMapHtml(String place) {
  final q = jsonEncode(place).replaceAll('<', r'\u003c');
  return _mapTemplate.replaceFirst('__PLACE__', q);
}

const String _mapTemplate = r'''<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<style>
html,body,#m{height:100%;margin:0;background:#000}
#t{position:absolute;z-index:999;top:12px;left:12px;right:12px;padding:12px 14px;border-radius:14px;
background:rgba(17,10,2,.92);color:#FFD54F;font:600 14px sans-serif;border:1px solid #FFA000;
box-shadow:0 0 18px rgba(255,109,0,.45)}
.leaflet-tile-pane{filter:invert(1) hue-rotate(180deg) brightness(.9) contrast(.9)}
</style></head><body>
<div id="t">Searching map...</div><div id="m"></div>
<script>
var q=__PLACE__;
var label=document.getElementById('t');
var map=L.map('m').setView([22.5,79],5);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'OpenStreetMap'}).addTo(map);
fetch('https://nominatim.openstreetmap.org/search?format=json&limit=1&q='+encodeURIComponent(q))
.then(function(r){return r.json();})
.then(function(d){
  if(!d.length){label.textContent='Place not found: '+q;return;}
  var ll=[parseFloat(d[0].lat),parseFloat(d[0].lon)];
  map.setView(ll,14);
  L.marker(ll).addTo(map).bindPopup(d[0].display_name).openPopup();
  label.textContent=d[0].display_name;
}).catch(function(){label.textContent='Map data could not load. Check your internet.';});
</script></body></html>''';

class PageViewerScreen extends StatefulWidget {
  const PageViewerScreen({super.key, required this.page});
  final GeneratedPage page;

  @override
  State<PageViewerScreen> createState() => _PageViewerScreenState();
}

class _PageViewerScreenState extends State<PageViewerScreen> {
  late final WebViewController _web;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..loadHtmlString(widget.page.html, baseUrl: 'https://jarvis.local/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: const Color(0xFFFFD54F),
        title: Text(widget.page.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Copy HTML code',
            icon: const Icon(Icons.copy_all),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: widget.page.html));
              messenger.showSnackBar(
                  const SnackBar(content: Text('HTML copied to clipboard')));
            },
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () => _web.loadHtmlString(widget.page.html,
                baseUrl: 'https://jarvis.local/'),
          ),
        ],
      ),
      body: SafeArea(child: WebViewWidget(controller: _web)),
    );
  }
}
