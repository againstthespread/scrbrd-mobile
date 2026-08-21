enum BleWakeRefreshAction {
  refreshPga,
  refreshBackgroundTeamSport,
  ignoreForegroundTeamSport,
}

BleWakeRefreshAction decideBleWakeRefresh({
  required bool hasTrackedGolf,
  required bool isAppBackgrounded,
}) {
  if (hasTrackedGolf) return BleWakeRefreshAction.refreshPga;
  return isAppBackgrounded
      ? BleWakeRefreshAction.refreshBackgroundTeamSport
      : BleWakeRefreshAction.ignoreForegroundTeamSport;
}
