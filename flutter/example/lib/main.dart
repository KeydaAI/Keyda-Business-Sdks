// The whole integration: init once at startup, then show it from anywhere.
//
// Replace the client id with your own from the dashboard's Install screen
// (Keyda Business → Install → Client ID). Nothing else is required — the chat
// itself is a hosted page, so there is no UI to build and no state to manage.
//
// The example's own widgets are not a public API, so the package-wide doc-comment
// lint is switched off here rather than padding them with comments.
// ignore_for_file: public_member_api_docs
import 'package:flutter/material.dart';
import 'package:keyda_bot/keyda_bot.dart';

void main() {
  // Shape-valid placeholder (kb_live_ + hex) so the example RUNS as shipped —
  // init validates the shape and throws otherwise. It opens the "chat link is
  // not valid" page until you replace it with your real id.
  KeydaBot.init('kb_live_0123456789ab');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keyda Bot example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B4EE0), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sharma Leather Works')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Your app goes here. Tap the button to open the assistant.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        // `context` is what tells KeydaBot which navigator to push onto.
        onPressed: () => KeydaBot.show(context),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Ask us anything'),
      ),
    );
  }
}
