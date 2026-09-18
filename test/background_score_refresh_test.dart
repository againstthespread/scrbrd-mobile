import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/background_score_refresh_dispatcher.dart';
import 'package:sports_hub_mobile/fantasy_live_observation_coordinator.dart';

void main() {
  test(
    'background score refresh runs sports and fantasy once then completes',
    () async {
      var sportsRuns = 0;
      var fantasyRuns = 0;
      var completions = 0;
      final diagnostics = <String>[];

      await runBackgroundScoreRefresh(
        refresh: () => runIsolatedWakeDomains(
          refreshSports: () async => sportsRuns++,
          observeFantasy: () async => fantasyRuns++,
          onDiagnostic: diagnostics.add,
          triggerLabel: 'FCM BACKGROUND SCORE REFRESH',
        ),
        complete: () => completions++,
      );

      expect(sportsRuns, 1);
      expect(fantasyRuns, 1);
      expect(completions, 1);
      expect(diagnostics, isEmpty);
    },
  );

  test(
    'sports failure does not prevent background fantasy observation',
    () async {
      var fantasyRuns = 0;
      final diagnostics = <String>[];

      await runIsolatedWakeDomains(
        refreshSports: () async => throw StateError('sports failed'),
        observeFantasy: () async => fantasyRuns++,
        onDiagnostic: diagnostics.add,
        triggerLabel: 'FCM BACKGROUND SCORE REFRESH',
      );

      expect(fantasyRuns, 1);
      expect(
        diagnostics.single,
        contains('FCM BACKGROUND SCORE REFRESH: sports failed'),
      );
    },
  );

  test('fantasy failure does not prevent background sports refresh', () async {
    var sportsRuns = 0;
    final diagnostics = <String>[];

    await runIsolatedWakeDomains(
      refreshSports: () async => sportsRuns++,
      observeFantasy: () async => throw StateError('fantasy failed'),
      onDiagnostic: diagnostics.add,
      triggerLabel: 'FCM BACKGROUND SCORE REFRESH',
    );

    expect(sportsRuns, 1);
    expect(
      diagnostics.single,
      contains('FCM BACKGROUND SCORE REFRESH: fantasy failed'),
    );
  });

  test('background request completes when the gated refresh throws', () async {
    var completions = 0;

    await expectLater(
      runBackgroundScoreRefresh(
        refresh: () async => throw StateError('gate failed'),
        complete: () => completions++,
      ),
      throwsA(isA<StateError>()),
    );

    expect(completions, 1);
  });

  test('BLE WAKE diagnostics retain their default trigger label', () async {
    final diagnostics = <String>[];

    await runIsolatedWakeDomains(
      refreshSports: () async => throw StateError('sports failed'),
      observeFantasy: () async {},
      onDiagnostic: diagnostics.add,
    );

    expect(diagnostics.single, contains('BLE WAKE: sports failed'));
  });
}
