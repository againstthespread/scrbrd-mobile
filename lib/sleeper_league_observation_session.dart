import 'fantasy_league_config.dart';
import 'fantasy_point_delta_tracker.dart';
import 'pending_fantasy_alert_store.dart';
import 'sleeper_models.dart';

/// Mutable scoring state owned exclusively by one provider-qualified league.
class SleeperLeagueObservationSession {
  SleeperLeagueObservationSession(
    this.config, {
    FantasyPointDeltaTracker? deltaTracker,
    PendingFantasyAlertStore? pendingStore,
  }) : deltaTracker = deltaTracker ?? FantasyPointDeltaTracker(),
       pendingStore = pendingStore ?? PendingFantasyAlertStore();

  FantasyLeagueConfig config;
  final FantasyPointDeltaTracker deltaTracker;
  final PendingFantasyAlertStore pendingStore;
  String? observationContext;
  SleeperFantasyMatchup? latestMatchup;
  bool baselineEstablished = false;
  int revision = 0;

  void updateConfiguration(FantasyLeagueConfig next) {
    if (config.teamId != next.teamId ||
        config.alertsEnabled != next.alertsEnabled) {
      reset();
    }
    config = next;
  }

  void reset() {
    revision++;
    deltaTracker.reset();
    pendingStore.clear();
    observationContext = null;
    latestMatchup = null;
    baselineEstablished = false;
  }
}
