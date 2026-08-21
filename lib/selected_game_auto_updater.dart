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
    this.serializer = const GamePacketSerializer(),
    this.canSend,
    this.onError,
    this.onDiagnostic,
  }) : _selectedGameKey = SelectedGameKey.fromGameData(selectedGame),
       _lastSentPacket = serializer.serializeToString(lastSentGame);

  final SportsRepository repository;
  final DeviceTransport transport;
  final SportsLeague league;
  final DateTime selectedDate;
  final GamePacketSerializer serializer;
  final Future<bool> Function()? canSend;
  final void Function(Object error)? onError;
  final void Function(String message)? onDiagnostic;
  final SelectedGameKey _selectedGameKey;

  bool _isRefreshing = false;
  bool _isPaused = false;
  String _lastSentPacket;

  void pause() {
    _isPaused = true;
    _diagnose('one-shot team refresh cancelled');
  }

  Future<void> refreshNow() async {
    if (_isRefreshing) {
      _diagnose('refresh skipped; previous refresh still running');
      return;
    }

    _diagnose('team refresh started; tracked event ID=${_selectedGameKey.id}');
    _isRefreshing = true;
    try {
      _diagnose('repository fetch started');
      final games = await repository.fetchGamesForDate(league, selectedDate);
      if (_isPaused) {
        _diagnose('team refresh abandoned: refresher cancelled');
        return;
      }
      _diagnose('fetch succeeded; games=${games.length}');
      final updatedGame = _findSelectedGame(games);
      _diagnose('tracked content found=${updatedGame != null}');
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
      final sendAllowed = await canSend?.call() ?? true;
      if (!sendAllowed) {
        _diagnose('BLE write skipped: wake refresh conditions changed');
        return;
      }
      try {
        await transport.sendGameData(updatedGame);
        _diagnose('BLE send succeeded; BLE write succeeded');
        _lastSentPacket = updatedPacket;
      } on Object catch (error) {
        _diagnose('BLE write failed: $error');
        onError?.call(error);
      }
    } on Object catch (error) {
      _diagnose('team refresh failed; waiting for next BLE wake: $error');
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
    _diagnose('one-shot team refresher disposed');
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
