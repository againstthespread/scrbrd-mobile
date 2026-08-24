import 'favorite_team.dart';
import 'sports_league.dart';

class TeamCatalog {
  const TeamCatalog._();

  static final List<FavoriteTeam> teams = List.unmodifiable([
    ..._league(
      SportsLeague.nfl,
      const {
        'ARI': 'Arizona Cardinals',
        'ATL': 'Atlanta Falcons',
        'BAL': 'Baltimore Ravens',
        'BUF': 'Buffalo Bills',
        'CAR': 'Carolina Panthers',
        'CHI': 'Chicago Bears',
        'CIN': 'Cincinnati Bengals',
        'CLE': 'Cleveland Browns',
        'DAL': 'Dallas Cowboys',
        'DEN': 'Denver Broncos',
        'DET': 'Detroit Lions',
        'GB': 'Green Bay Packers',
        'HOU': 'Houston Texans',
        'IND': 'Indianapolis Colts',
        'JAX': 'Jacksonville Jaguars',
        'KC': 'Kansas City Chiefs',
        'LV': 'Las Vegas Raiders',
        'LAC': 'Los Angeles Chargers',
        'LAR': 'Los Angeles Rams',
        'MIA': 'Miami Dolphins',
        'MIN': 'Minnesota Vikings',
        'NE': 'New England Patriots',
        'NO': 'New Orleans Saints',
        'NYG': 'New York Giants',
        'NYJ': 'New York Jets',
        'PHI': 'Philadelphia Eagles',
        'PIT': 'Pittsburgh Steelers',
        'SEA': 'Seattle Seahawks',
        'SF': 'San Francisco 49ers',
        'TB': 'Tampa Bay Buccaneers',
        'TEN': 'Tennessee Titans',
        'WAS': 'Washington Commanders',
      },
      aliases: const {
        'JAX': {'JAC'},
        'WAS': {'WSH'},
      },
    ),
    ..._league(
      SportsLeague.nba,
      const {
        'ATL': 'Atlanta Hawks',
        'BOS': 'Boston Celtics',
        'BKN': 'Brooklyn Nets',
        'CHA': 'Charlotte Hornets',
        'CHI': 'Chicago Bulls',
        'CLE': 'Cleveland Cavaliers',
        'DAL': 'Dallas Mavericks',
        'DEN': 'Denver Nuggets',
        'DET': 'Detroit Pistons',
        'GSW': 'Golden State Warriors',
        'HOU': 'Houston Rockets',
        'IND': 'Indiana Pacers',
        'LAC': 'LA Clippers',
        'LAL': 'Los Angeles Lakers',
        'MEM': 'Memphis Grizzlies',
        'MIA': 'Miami Heat',
        'MIL': 'Milwaukee Bucks',
        'MIN': 'Minnesota Timberwolves',
        'NOP': 'New Orleans Pelicans',
        'NYK': 'New York Knicks',
        'OKC': 'Oklahoma City Thunder',
        'ORL': 'Orlando Magic',
        'PHI': 'Philadelphia 76ers',
        'PHX': 'Phoenix Suns',
        'POR': 'Portland Trail Blazers',
        'SAC': 'Sacramento Kings',
        'SAS': 'San Antonio Spurs',
        'TOR': 'Toronto Raptors',
        'UTA': 'Utah Jazz',
        'WAS': 'Washington Wizards',
      },
      aliases: const {
        'GSW': {'GS'},
        'NOP': {'NO'},
        'NYK': {'NY'},
        'SAS': {'SA'},
        'UTA': {'UTAH'},
        'WAS': {'WSH'},
      },
    ),
    ..._league(
      SportsLeague.mlb,
      const {
        'ARI': 'Arizona Diamondbacks',
        'ATL': 'Atlanta Braves',
        'BAL': 'Baltimore Orioles',
        'BOS': 'Boston Red Sox',
        'CHC': 'Chicago Cubs',
        'CWS': 'Chicago White Sox',
        'CIN': 'Cincinnati Reds',
        'CLE': 'Cleveland Guardians',
        'COL': 'Colorado Rockies',
        'DET': 'Detroit Tigers',
        'HOU': 'Houston Astros',
        'KC': 'Kansas City Royals',
        'LAA': 'Los Angeles Angels',
        'LAD': 'Los Angeles Dodgers',
        'MIA': 'Miami Marlins',
        'MIL': 'Milwaukee Brewers',
        'MIN': 'Minnesota Twins',
        'NYM': 'New York Mets',
        'NYY': 'New York Yankees',
        'ATH': 'Athletics',
        'PHI': 'Philadelphia Phillies',
        'PIT': 'Pittsburgh Pirates',
        'SD': 'San Diego Padres',
        'SF': 'San Francisco Giants',
        'SEA': 'Seattle Mariners',
        'STL': 'St. Louis Cardinals',
        'TB': 'Tampa Bay Rays',
        'TEX': 'Texas Rangers',
        'TOR': 'Toronto Blue Jays',
        'WAS': 'Washington Nationals',
      },
      aliases: const {
        'ATH': {'OAK', 'Oakland Athletics'},
        'CWS': {'CHW'},
        'KC': {'KCR'},
        'SD': {'SDP'},
        'SF': {'SFG'},
        'TB': {'TBR'},
        'WAS': {'WSH'},
      },
    ),
  ]);

  static List<FavoriteTeam> forLeague(SportsLeague league) =>
      List.unmodifiable(teams.where((team) => team.league == league));

  static FavoriteTeam? byStorageKey(String value) {
    for (final team in teams) {
      if (team.storageKey == value) return team;
    }
    return null;
  }

  static String? canonicalKey(SportsLeague league, String providerValue) {
    final needle = _normalize(providerValue);
    for (final team in teams) {
      if (team.league != league) continue;
      final values = {
        team.key,
        team.abbreviation,
        team.displayName,
        ...team.aliases,
      };
      if (values.any((value) => _normalize(value) == needle)) return team.key;
    }
    return null;
  }

  static List<FavoriteTeam> _league(
    SportsLeague league,
    Map<String, String> values, {
    Map<String, Set<String>> aliases = const {},
  }) => [
    for (final entry in values.entries)
      FavoriteTeam(
        league: league,
        key: entry.key,
        abbreviation: entry.key,
        displayName: entry.value,
        aliases: aliases[entry.key] ?? const {},
      ),
  ];

  static String _normalize(String value) => value.trim().toUpperCase();
}
