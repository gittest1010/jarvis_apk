// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// FIX: The project name (from pubspec.yaml) is 'voice_assistant', not 'jarvis'.
import 'package:voice_assistant/main.dart';

void main() {
  // UPDATED TEST: This test now checks for UI elements from your actual app,
  // not the default counter app.
  testWidgets('Voice Assistant UI smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that the AppBar title is correct.
    expect(find.text('Smart Voice Assistant'), findsOneWidget);

    // Verify that the initial instruction text is present.
    expect(find.text('Tap the mic and start speaking...'), findsOneWidget);

    // Verify that the initial microphone icon is present.
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });
}
