import 'dart:async';

import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';
import 'sports_league.dart';
import 'sports_repository.dart';

class SelectedGameAutoUpdater {
  SelectedGameAutoUpdater({
    required this.repository,
    required this.transport,
    required this.league,
    required this.selectedDate,
    required GameData selectedGame,
    required GameData lastSentGame,
    this.refreshInterval = defaultRefreshInterval,
    this.serializer = const GamePacketSerializer(),
    this.onError,
    this.onDiagnostic,
  }) : _selectedGameKey = SelectedGameKey.fromGameData(selectedGame),
       _lastSentPacket = serializer.serializeToString(lastSentGame);

  static const defaultRefreshInterval = Duration(seconds: 30);

  final SportsRepository repository;
  final DeviceTransport transport;
  final SportsLeague league;
  final DateTime selectedDate;
  final Duration refreshInterval;
  final GamePacketSerializer serializer;
  final void Function(Object error)? onError;
  final void Function(String message)? onDiagnostic;
  final SelectedGameKey _selectedGameKey;

  Timer? _timer;
  bool _isRefreshing = false;
  bool _isPaused = false;
  String _lastSentPacket;

  void start() {
    _isPaused = false;
    _timer?.cancel();
    _diagnose('updater started; interval=${refreshInterval.inSeconds}s');
    _timer = Timer.periodic(refreshInterval, (_) => refreshNow());
  }

  void pause() {
    _isPaused = true;
    _diagnose('updater paused');
    _timer?.cancel();
    _timer = null;
  }

  void resume({GameData? lastSentGame}) {
    if (lastSentGame != null) {
      _lastSentPacket = serializer.serializeToString(lastSentGame);
    }
    _diagnose('updater resumed');
    start();
  }

  Future<void> refreshNow() async {
    if (_isRefreshing) {
      _diagnose('refresh skipped; previous refresh still running');
      return;
    }

    _diagnose('poll started; tracked game identifier=${_selectedGameKey.id}');
    _isRefreshing = true;
    try {
      _diagnose('repository fetch started');
      final games = await repository.fetchGamesForDate(league, selectedDate);
      if (_isPaused) {
        _diagnose('poll abandoned: updater paused or stopped');
        return;
      }
      _diagnose('repository fetch succeeded; games=${games.length}');
      final updatedGame = _findSelectedGame(games);
      _diagnose('selected game match found=${updatedGame != null}');
      if (updatedGame == null) {
        return;
      }

      final updatedPacket = serializer.serializeToString(updatedGame);
      final packetChanged = updatedPacket != _lastSentPacket;
      _diagnose('serialized packet changed=$packetChanged');
      if (!packetChanged) {
        _diagnose('no relevant change; BLE send attempted=false');
        return;
      }

      _diagnose(
        'change detected; BLE send attempted=true; BLE write attempted',
      );
      try {
        await transport.sendGameData(updatedGame);
        _diagnose('BLE send succeeded; BLE write succeeded');
        _lastSentPacket = updatedPacket;
      } on Object catch (error) {
        _diagnose('BLE write failed: $error');
        onError?.call(error);
      }
    } on Object catch (error) {
      _diagnose('poll failed; will retry at normal interval: $error');
      onError?.call(error);
    } finally {
      _isRefreshing = false;
    }
  }

  GameData? _findSelectedGame(List<GameData> games) {
    for (final game in games) {
      if (SelectedGameKey.fromGameData(game) == _selectedGameKey) {
        return game;
      }
    }

    return null;
  }

  void dispose() {
    _isPaused = true;
    _diagnose('updater stopped/disposed');
    _timer?.cancel();
    _timer = null;
  }

  void _diagnose(String message) {
    onDiagnostic?.call(message);
  }
}

class SelectedGameKey {
  const SelectedGameKey({
    required this.eventId,
    required this.league,
    required this.awayTeam,
    required this.homeTeam,
    required this.scheduledStartTime,
  });

  factory SelectedGameKey.fromGameData(GameData gameData) {
    return SelectedGameKey(
      eventId: gameData.eventId?.trim(),
      league: gameData.league.trim().toUpperCase(),
      awayTeam: gameData.awayTeam.trim().toUpperCase(),
      homeTeam: gameData.homeTeam.trim().toUpperCase(),
      scheduledStartTime: gameData.scheduledStartTime,
    );
  }

  final String league;
  final String? eventId;
  final String awayTeam;
  final String homeTeam;
  final DateTime? scheduledStartTime;

  String get id {
    final stableEventId = eventId;
    if (stableEventId != null && stableEventId.isNotEmpty) {
      return '$league:$stableEventId';
    }

    return '$league:$awayTeam:$homeTeam:'
        '${scheduledStartTime?.toIso8601String() ?? 'unknown-start'}';
  }

  @override
  bool operator ==(Object other) {
    if (other is! SelectedGameKey || other.league != league) {
      return false;
    }

    final stableEventId = eventId;
    final otherStableEventId = other.eventId;
    if (stableEventId != null &&
        stableEventId.isNotEmpty &&
        otherStableEventId != null &&
        otherStableEventId.isNotEmpty) {
      return stableEventId == otherStableEventId;
    }

    if ((stableEventId != null && stableEventId.isNotEmpty) ||
        (otherStableEventId != null && otherStableEventId.isNotEmpty)) {
      return false;
    }

    return other.awayTeam == awayTeam &&
        other.homeTeam == homeTeam &&
        _sameScheduledStart(other.scheduledStartTime, scheduledStartTime);
  }

  @override
  int get hashCode {
    final stableEventId = eventId;
    if (stableEventId != null && stableEventId.isNotEmpty) {
      return Object.hash(league, stableEventId);
    }

    return Object.hash(
      league,
      awayTeam,
      homeTeam,
      scheduledStartTime?.millisecondsSinceEpoch,
    );
  }

  static bool _sameScheduledStart(DateTime? a, DateTime? b) {
    if (a == null || b == null) {
      return a == null && b == null;
    }

    return a.isAtSameMomentAs(b);
  }
}
