import 'espn_fantasy_client.dart';
import 'espn_fantasy_credentials.dart';
import 'espn_fantasy_repository.dart';
import 'fantasy_provider_models.dart';

/// UI-facing seam for account validation and league setup. Validation uses
/// the supplied cookies only in memory; the caller saves them on success.
abstract interface class EspnFantasySetupGateway {
  Future<FantasyLeagueDetails> validateAndLoadLeague(
    EspnFantasyCredentials credentials,
    int season,
    String leagueId,
  );
  Future<FantasyLeagueDetails> loadLeague(int season, String leagueId);
  Future<FantasyMatchupSnapshot> loadMatchup(
    int season,
    String leagueId,
    String teamId,
  );
}

class DeviceEspnFantasySetupGateway implements EspnFantasySetupGateway {
  DeviceEspnFantasySetupGateway(this.credentialsStore);
  final EspnFantasyCredentialsStore credentialsStore;

  @override
  Future<FantasyLeagueDetails> validateAndLoadLeague(
    EspnFantasyCredentials credentials,
    int season,
    String leagueId,
  ) async {
    if (!credentials.isValid) {
      throw const EspnFantasyException(EspnFantasyFailure.unauthorized);
    }
    final client = EspnFantasyClient(
      credentialsStore: _TemporaryCredentialsStore(credentials),
    );
    try {
      return await EspnFantasyRepository(
        client,
      ).loadLeague(season: season, leagueId: leagueId);
    } finally {
      client.close();
    }
  }

  @override
  Future<FantasyLeagueDetails> loadLeague(int season, String leagueId) async {
    final client = EspnFantasyClient(credentialsStore: credentialsStore);
    try {
      return await EspnFantasyRepository(
        client,
      ).loadLeague(season: season, leagueId: leagueId);
    } finally {
      client.close();
    }
  }

  @override
  Future<FantasyMatchupSnapshot> loadMatchup(
    int season,
    String leagueId,
    String teamId,
  ) async {
    final client = EspnFantasyClient(credentialsStore: credentialsStore);
    try {
      return await EspnFantasyRepository(
        client,
      ).loadCurrentMatchup(season: season, leagueId: leagueId, teamId: teamId);
    } finally {
      client.close();
    }
  }
}

class _TemporaryCredentialsStore implements EspnFantasyCredentialsStore {
  _TemporaryCredentialsStore(this._credentials);
  final EspnFantasyCredentials _credentials;
  @override
  Future<EspnFantasyCredentials?> read() async => _credentials;
  @override
  Future<bool> hasCredentials() async => true;
  @override
  Future<void> save(EspnFantasyCredentials credentials) async =>
      throw UnsupportedError('Temporary credentials are read only');
  @override
  Future<void> clear() async =>
      throw UnsupportedError('Temporary credentials are read only');
}
