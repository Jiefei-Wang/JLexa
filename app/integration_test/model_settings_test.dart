import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jlexa/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> scrollUntilFound(
    WidgetTester tester,
    Finder finder, {
    int maxDrags = 10,
  }) async {
    for (var i = 0; i < maxDrags; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
    }
  }

  testWidgets('Model settings and catalog navigation integration test', (
    WidgetTester tester,
  ) async {
    app.main();
    await tester.pumpAndSettle(const Duration(milliseconds: 2000));

    // 1. Verify Home screen is loaded
    expect(find.text('JLexa'), findsOneWidget);

    // 2. Tap Settings icon on app bar
    final settingsIcon = find.byIcon(Icons.settings_outlined);
    expect(settingsIcon, findsOneWidget);
    await tester.tap(settingsIcon);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // 3. Verify Settings & Local Models screen opened
    expect(find.text('Settings & Local Models'), findsOneWidget);
    expect(find.text('Local Language Model (LLM)'), findsOneWidget);

    // 4. Verify Curated LLM Model Names appear on screen
    expect(find.text('Qwen2.5 0.5B Instruct'), findsOneWidget);
    expect(find.text('RECOMMENDED'), findsWidgets);

    // 5. Scroll down to Import Local GGUF (bottom of LLM section)
    final importGguf = find.text('Import Local GGUF');
    await scrollUntilFound(tester, importGguf);
    expect(importGguf, findsOneWidget);

    // 6. Scroll down to Whisper models section
    final whisperHeader = find.text('Speech Recognition Model (Whisper)');
    await scrollUntilFound(tester, whisperHeader);
    expect(whisperHeader, findsOneWidget);

    final whisperBase = find.text('Whisper Base (English)');
    await scrollUntilFound(tester, whisperBase);
    expect(whisperBase, findsOneWidget);

    // 7. Scroll down to Import Local Whisper Model (bottom of Whisper section)
    final importWhisper = find.text('Import Local Whisper Model');
    await scrollUntilFound(tester, importWhisper);
    expect(importWhisper, findsOneWidget);

    // 8. Scroll down to Inference Configuration
    final inferenceHeader = find.text('Inference Configuration');
    await scrollUntilFound(tester, inferenceHeader);
    expect(inferenceHeader, findsOneWidget);

    final temperature = find.text('Temperature');
    await scrollUntilFound(tester, temperature);
    expect(temperature, findsOneWidget);

    // 9. Pop back to Home
    final backButton = find.byTooltip('Back');
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.text('JLexa'), findsOneWidget);
    }
  });
}
