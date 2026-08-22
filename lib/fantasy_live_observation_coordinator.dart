import 'package:flutter/foundation.dart';

import 'device_transport.dart';
import 'fantasy_nfl_play.dart';
import 'fantasy_point_delta_tracker.dart';
import 'fantasy_scoring_correlation.dart';
import 'pending_fantasy_alert_store.dart';
import 'sleeper_fantasy_repository.dart';
import 'sleeper_league_id_store.dart';
import 'sleeper_models.dart';
import 'sleeper_roster_id_store.dart';

typedef FantasyLeagueLoader =
    Future<SleeperLeagueSnapshot> Function(String leagueId);
typedef FantasyPlayRefresher =
    Future<List<FantasyNflPlay>> Function(DateTime date);
typedef FantasyMetadataResolver =
    Future<Map<String, SleeperFantasyPlayer>> Function(
      Iterable<String> playerIds,
    );

Future<void> runIsolatedWakeDomains({
  required Future<void> Function() refreshSports,
  required Future<void> Function() observeFantasy,
  void Function(String message)? onDiagnostic,
}) async {
  try {
    await refreshSports();
  } on Object catch (error) {
    onDiagnostic?.call(
      'SPORTS WAKE failed; fantasy observation continues: $error',
    );
  }
  try {
    await observeFantasy();
  } on Object catch (error) {
    onDiagnostic?.call(
      'FANTASY WAKE failed; sports refresh unaffected: $error',
    );
  }
}

class FantasyObservationResult {
  const FantasyObservationResult({
    required this.configured,
    required this.baselineReady,
    required this.events,
    required this.newPlays,
    required this.summary,
    this.matchup,
  });

  final bool configured;
  final bool baselineReady;
  final List<FantasyScoringEvent> events;
  final List<FantasyNflPlay> newPlays;
  final String summary;
  final SleeperFantasyMatchup? matchup;
}

class FantasyRuntimeStatus {
  const FantasyRuntimeStatus({
    this.configured = false,
    this.baselineReady = false,
    this.pendingAlerts = 0,
    this.lastObservation,
    this.lastResult = 'Not observed yet.',
  });

  final bool configured;
  final bool baselineReady;
  final int pendingAlerts;
  final DateTime? lastObservation;
  final String lastResult;
}

/// Long-lived, connection-session fantasy runtime invoked by the existing WAKE.
class FantasyLiveObservationCoordinator extends ChangeNotifier {
  FantasyLiveObservationCoordinator({
    required this.leagueIdStore,
    required this.rosterIdStore,
    required this.loadLeague,
    required this.refreshPlays,
    required this.resolveCachedMetadata,
    required this.transport,
    required this.isBleConnected,
    FantasyPointDeltaTracker? deltaTracker,
    this.correlator = const FantasyScoringCorrelator(),
    PendingFantasyAlertStore? pendingStore,
    DateTime Function()? clock,
    this.onDiagnostic,
  }) : deltaTracker = deltaTracker ?? FantasyPointDeltaTracker(),
       pendingStore = pendingStore ?? PendingFantasyAlertStore(),
       clock = clock ?? DateTime.now;

  final SleeperLeagueIdStore leagueIdStore;
  final SleeperRosterIdStore rosterIdStore;
  final FantasyLeagueLoader loadLeague;
  final FantasyPlayRefresher refreshPlays;
  final FantasyMetadataResolver resolveCachedMetadata;
  final DeviceTransport transport;
  final bool Function() isBleConnected;
  final FantasyPointDeltaTracker deltaTracker;
  final FantasyScoringCorrelator correlator;
  final PendingFantasyAlertStore pendingStore;
  final DateTime Function() clock;
  final void Function(String message)? onDiagnostic;

  FantasyRuntimeStatus _status = const FantasyRuntimeStatus();
  bool _observing = false;
  final List<FantasyNflPlay> _recentPlays = [];

  FantasyRuntimeStatus get status => _status;

  Future<FantasyObservationResult> observe({bool sendOneAlert = true}) async {
    if (_observing) {
      return FantasyObservationResult(
        configured: _status.configured,
        baselineReady: _status.baselineReady,
        events: const [],
        newPlays: const [],
        summary: 'Skipped: fantasy observation already active.',
      );
    }
    _observing = true;
    try {
      final leagueId = (await leagueIdStore.read())?.trim();
      final rosterId = await rosterIdStore.read();
      if (leagueId == null || leagueId.isEmpty || rosterId == null) {
        return _finish(
          const FantasyObservationResult(
            configured: false,
            baselineReady: false,
            events: [],
            newPlays: [],
            summary: 'Skipped: Sleeper league or roster is not configured.',
          ),
        );
      }

      final snapshot = await loadLeague(leagueId);
      final matchup = snapshot.matchupForRoster(rosterId);
      final context = FantasyMatchupContext(
        leagueId: snapshot.league.leagueId,
        week: snapshot.week,
        rosterId: matchup.team.roster.rosterId,
        opponentRosterId: matchup.opponent.roster.rosterId,
        matchupId: matchup.team.matchup.matchupId,
      );
      final contextChanged = pendingStore.context != context;
      pendingStore.useContext(context);
      if (contextChanged) _recentPlays.clear();
      _diagnose(
        'FANTASY WAKE: configured=true; week=${snapshot.week}; '
        'matchup=${matchup.team.matchup.matchupId}',
      );
      final deltaResult = deltaTracker.observe(matchup);
      _diagnose('FANTASY SLEEPER: deltas=${deltaResult.events.length}');

      List<FantasyNflPlay> plays = const [];
      var espnSucceeded = false;
      try {
        plays = await refreshPlays(clock());
        espnSucceeded = true;
        _rememberRecentPlays(plays);
        _diagnose('FANTASY ESPN: newPlays=${plays.length}');
      } on Object catch (error) {
        _diagnose(
          'FANTASY ESPN failed; authoritative Sleeper deltas preserved as '
          'unmatched events: $error',
        );
      }

      final starterIds = deltaResult.events.map((event) => event.playerId);
      final metadata = await resolveCachedMetadata(starterIds);
      final events = correlator.correlate(
        deltas: deltaResult.events,
        players: metadata,
        plays: espnSucceeded ? _recentPlays : const [],
        scoringSettings: snapshot.league.scoringSettings,
      );
      for (final event in events) {
        _diagnose('FANTASY CORRELATION: ${event.diagnostic}');
        final id = fantasyTransitionId(context, event.delta);
        final added = pendingStore.add(
          PendingFantasyAlert(
            id: id,
            context: context,
            event: event,
            userName: matchup.team.name,
            userScore: matchup.team.matchup.points,
            opponentName: matchup.opponent.name,
            opponentScore: matchup.opponent.matchup.points,
          ),
        );
        if (added) _diagnose('FANTASY ALERT QUEUED: id=$id');
      }

      if (sendOneAlert) await _sendNext();
      return _finish(
        FantasyObservationResult(
          configured: true,
          baselineReady: true,
          events: List.unmodifiable(events),
          newPlays: List.unmodifiable(plays),
          summary: deltaResult.baselineReset
              ? 'Baseline established; no historical alerts.'
              : 'Observed ${events.length} new fantasy event(s).',
          matchup: matchup,
        ),
      );
    } on Object catch (error) {
      _diagnose('FANTASY SLEEPER failed; sports refresh unaffected: $error');
      return _finish(
        FantasyObservationResult(
          configured: true,
          baselineReady: _status.baselineReady,
          events: const [],
          newPlays: const [],
          summary: 'Fantasy observation failed: $error',
        ),
      );
    } finally {
      _observing = false;
    }
  }

  Future<void> _sendNext() async {
    final alert = pendingStore.next;
    if (alert == null || !isBleConnected()) return;
    _diagnose(
      'FANTASY ALERT SEND: player='
      '${alert.event.player?.fullName ?? alert.event.delta.playerId}; '
      'delta=${alert.event.delta.delta}',
    );
    try {
      await transport.sendFantasyAlert(
        alert.event,
        userName: alert.userName,
        userScore: alert.userScore,
        opponentName: alert.opponentName,
        opponentScore: alert.opponentScore,
      );
      pendingStore.markDelivered(alert.id);
      _diagnose('FANTASY ALERT DELIVERED: id=${alert.id}');
    } on Object catch (error) {
      _diagnose('FANTASY ALERT SEND failed; retained: ${alert.id}; $error');
    }
  }

  void _rememberRecentPlays(List<FantasyNflPlay> plays) {
    for (final play in plays) {
      _recentPlays.removeWhere(
        (existing) =>
            existing.gameId == play.gameId && existing.playId == play.playId,
      );
      _recentPlays.add(play);
    }
    const maximumRecentPlays = 50;
    if (_recentPlays.length > maximumRecentPlays) {
      _recentPlays.removeRange(0, _recentPlays.length - maximumRecentPlays);
    }
  }

  FantasyObservationResult _finish(FantasyObservationResult result) {
    _status = FantasyRuntimeStatus(
      configured: result.configured,
      baselineReady: result.baselineReady,
      pendingAlerts: pendingStore.length,
      lastObservation: clock(),
      lastResult: result.summary,
    );
    notifyListeners();
    return result;
  }

  void _diagnose(String message) => onDiagnostic?.call(message);
}
