// The whole integration: init once at startup, then show it from anywhere.
//
// Replace the client id with your own from the dashboard's Install screen
// (Keyda Business → Install → Client ID). Nothing else is required — the chat
// itself is a hosted page, so there is no UI to build and no state to manage.
import 'package:flutter/material.dart';
import 'package:keyda_bot/keyda_bot.dart';

void main() {
  KeydaBot.init('kb_live_replace_with_your_client_id');
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
