import 'package:flutter_test/flutter_test.dart';
import 'package:sports_hub_mobile/ble_wake_refresh_policy.dart';

void main() {
  test('foreground PGA wake triggers PGA refresh', () {
    expect(
      decideBleWakeRefresh(hasTrackedGolf: true, isAppBackgrounded: false),
      BleWakeRefreshAction.refreshPga,
    );
  });

  test('background PGA wake triggers PGA refresh', () {
    expect(
      decideBleWakeRefresh(hasTrackedGolf: true, isAppBackgrounded: true),
      BleWakeRefreshAction.refreshPga,
    );
  });

  test('foreground team-sport wake remains ignored', () {
    expect(
      decideBleWakeRefresh(hasTrackedGolf: false, isAppBackgrounded: false),
      BleWakeRefreshAction.ignoreForegroundTeamSport,
    );
  });

  test('background team-sport wake keeps existing refresh path', () {
    expect(
      decideBleWakeRefresh(hasTrackedGolf: false, isAppBackgrounded: true),
      BleWakeRefreshAction.refreshBackgroundTeamSport,
    );
  });
}
