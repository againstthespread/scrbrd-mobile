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
  String _lastSentPacket;

  void start() {
    _timer?.cancel();
    _diagnose('updater started; interval=${refreshInterval.inSeconds}s');
    _timer = Timer.periodic(refreshInterval, (_) => refreshNow());
  }

  Future<void> refreshNow() async {
    if (_isRefreshing) {
      _diagnose('refresh skipped; previous refresh still running');
      return;
    }

    _diagnose(
      'timer fired; checking ${_selectedGameKey.awayTeam} at '
      '${_selectedGameKey.homeTeam} (${_selectedGameKey.league})',
    );
    _isRefreshing = true;
    try {
      _diagnose('repository fetch started');
      final games = await repository.fetchGamesForDate(league, selectedDate);
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
        _diagnose('BLE send attempted=false');
        return;
      }

      _diagnose('BLE send attempted=true');
      await transport.sendGameData(updatedGame);
      _diagnose('BLE send succeeded');
      _lastSentPacket = updatedPacket;
    } on Object catch (error) {
      _diagnose('error=$error');
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
