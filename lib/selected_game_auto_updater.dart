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
  final SelectedGameKey _selectedGameKey;

  Timer? _timer;
  bool _isRefreshing = false;
  String _lastSentPacket;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(refreshInterval, (_) => refreshNow());
  }

  Future<void> refreshNow() async {
    if (_isRefreshing) {
      return;
    }

    _isRefreshing = true;
    try {
      final games = await repository.fetchGamesForDate(league, selectedDate);
      final updatedGame = _findSelectedGame(games);
      if (updatedGame == null) {
        return;
      }

      final updatedPacket = serializer.serializeToString(updatedGame);
      final packetChanged = updatedPacket != _lastSentPacket;
      if (!packetChanged) {
        return;
      }

      await transport.sendGameData(updatedGame);
      _lastSentPacket = updatedPacket;
    } on Object catch (error) {
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
    _timer?.cancel();
    _timer = null;
  }
}

class SelectedGameKey {
  const SelectedGameKey({
    required this.league,
    required this.awayTeam,
    required this.homeTeam,
    required this.scheduledStartTime,
  });

  factory SelectedGameKey.fromGameData(GameData gameData) {
    return SelectedGameKey(
      league: gameData.league.trim().toUpperCase(),
      awayTeam: gameData.awayTeam.trim().toUpperCase(),
      homeTeam: gameData.homeTeam.trim().toUpperCase(),
      scheduledStartTime: gameData.scheduledStartTime,
    );
  }

  final String league;
  final String awayTeam;
  final String homeTeam;
  final DateTime? scheduledStartTime;

  @override
  bool operator ==(Object other) {
    return other is SelectedGameKey &&
        other.league == league &&
        other.awayTeam == awayTeam &&
        other.homeTeam == homeTeam &&
        _sameScheduledStart(other.scheduledStartTime, scheduledStartTime);
  }

  @override
  int get hashCode {
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
