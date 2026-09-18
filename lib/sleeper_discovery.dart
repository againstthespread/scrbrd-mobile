import 'sleeper_models.dart';

class SleeperAccount {
  const SleeperAccount({required this.userId, required this.username});

  factory SleeperAccount.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final username = json['username'];
    if (userId is! String ||
        userId.trim().isEmpty ||
        username is! String ||
        username.trim().isEmpty) {
      throw const FormatException('Sleeper user response is missing identity.');
    }
    return SleeperAccount(userId: userId, username: username);
  }

  final String userId;
  final String username;
}

class SleeperDiscoveredLeague {
  const SleeperDiscoveredLeague({
    required this.league,
    required this.rosterId,
    required this.teamDisplayName,
    required this.rosters,
  });

  final SleeperLeague league;
  final int? rosterId;
  final String? teamDisplayName;
  final List<SleeperDiscoveryRoster> rosters;

  SleeperDiscoveredLeague copyWith({int? rosterId, String? teamDisplayName}) =>
      SleeperDiscoveredLeague(
        league: league,
        rosterId: rosterId ?? this.rosterId,
        teamDisplayName: teamDisplayName ?? this.teamDisplayName,
        rosters: rosters,
      );
}

class SleeperDiscoveryRoster {
  const SleeperDiscoveryRoster({required this.rosterId, required this.name});
  final int rosterId;
  final String name;
}
