import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class AkedlyTurnstile extends StatefulWidget {
  final String siteKey;
  final void Function(String token) onToken;
  final void Function(String error)? onError;
  final String bridgeDomain;

  const AkedlyTurnstile({
    super.key,
    required this.siteKey,
    required this.onToken,
    this.onError,
    this.bridgeDomain = 'turnstile.akedly.io',
  });

  @override
  State<AkedlyTurnstile> createState() => _AkedlyTurnstileState();
}

class _AkedlyTurnstileState extends State<AkedlyTurnstile> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Turnstile',
        onMessageReceived: _onMessage,
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _controller.runJavaScript('''
            window.addEventListener('message', function(e) {
              if (e.data && e.data.event) {
                Turnstile.postMessage(JSON.stringify(e.data));
              }
            });
          ''');
        },
      ))
      ..loadRequest(Uri.parse(
        'https://${widget.bridgeDomain}/challenge?sitekey=${widget.siteKey}',
      ));
  }

  void _onMessage(JavaScriptMessage message) {
    try {
      final data = json.decode(message.message);
      if (data['event'] == 'verify' && data['token'] != null) {
        widget.onToken(data['token']);
      } else if (data['event'] == 'error' && widget.onError != null) {
        widget.onError!(data['error'] ?? 'Unknown error');
      } else if (data['event'] == 'expired' && widget.onError != null) {
        widget.onError!('Token expired');
      }
    } catch (e) {
      widget.onError?.call('Failed to parse message: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 0,
      height: 0,
      child: WebViewWidget(controller: _controller),
    );
  }
}
