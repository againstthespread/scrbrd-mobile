import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/game_editor.dart';
import 'package:sports_hub_mobile/main.dart';

void main() {
  testWidgets('launches the SCRBRD Home screen', (tester) async {
    await tester.pumpWidget(const SportsHubApp());

    expect(find.text('SCRBRD'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect to SCRBRD'), findsOneWidget);
    expect(find.text('Peter Sports Hub'), findsNothing);
  });

  testWidgets('manual editor previews the protocol JSON packet', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: GameEditor())),
      ),
    );

    expect(find.text('Game Packet'), findsOneWidget);

    final previewButton = find.widgetWithText(FilledButton, 'Preview Packet');
    await tester.ensureVisible(previewButton);
    await tester.tap(previewButton);
    await tester.pump();

    expect(
      find.text(
        '{"version":1,"type":"game","league":"NFL","away":"Bills","home":"Patriots","awayScore":17,"homeScore":24,"status":"LIVE","clock":"Q4 8:31"}',
      ),
      findsOneWidget,
    );
  });
}
