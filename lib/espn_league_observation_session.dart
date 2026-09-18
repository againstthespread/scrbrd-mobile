import 'fantasy_league_config.dart';
import 'fantasy_point_delta_tracker.dart';
import 'fantasy_provider_models.dart';
import 'pending_fantasy_alert_store.dart';

/// Mutable scoring state owned exclusively by one ESPN league configuration.
class EspnLeagueObservationSession {
  EspnLeagueObservationSession(this.config)
    : deltaTracker = FantasyNormalizedPointDeltaTracker(),
      pendingStore = PendingFantasyAlertStore();

  FantasyLeagueConfig config;
  final FantasyNormalizedPointDeltaTracker deltaTracker;
  final PendingFantasyAlertStore pendingStore;
  String? observationContext;
  FantasyMatchupSnapshot? latestMatchup;
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
