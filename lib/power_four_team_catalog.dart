import 'college_football.dart';

class CollegeFootballTeam {
  const CollegeFootballTeam({
    required this.key,
    required this.displayName,
    required this.abbreviation,
    required this.conference,
    this.aliases = const {},
  });
  final String key;
  final String displayName;
  final String abbreviation;
  final NcaafConference conference;
  final Set<String> aliases;
}

class PowerFourTeamCatalog {
  const PowerFourTeamCatalog._();

  static final List<CollegeFootballTeam> teams = List.unmodifiable([
    ..._conference(
      NcaafConference.acc,
      const {
        'BC': 'Boston College',
        'CAL': 'California',
        'CLEM': 'Clemson',
        'DUKE': 'Duke',
        'FSU': 'Florida State',
        'GT': 'Georgia Tech',
        'LOU': 'Louisville',
        'MIA': 'Miami (FL)',
        'NCST': 'NC State',
        'UNC': 'North Carolina',
        'PITT': 'Pittsburgh',
        'SMU': 'SMU',
        'STAN': 'Stanford',
        'SYR': 'Syracuse',
        'UVA': 'Virginia',
        'VT': 'Virginia Tech',
        'WAKE': 'Wake Forest',
      },
      const {
        'CLEM': {'Clemson Tigers'},
        'FSU': {'Florida State Seminoles'},
        'GT': {'GTCH'},
        'MIA': {'Miami', 'Miami Hurricanes', 'MIAMI'},
        'NCST': {'North Carolina State', 'NCSU'},
        'UNC': {'North Carolina Tar Heels'},
        'PITT': {'Pittsburgh Panthers'},
        'UVA': {'Virginia Cavaliers'},
        'VT': {'VTECH'},
        'WAKE': {'WF'},
      },
    ),
    ..._conference(
      NcaafConference.bigTen,
      const {
        'ILL': 'Illinois',
        'IND': 'Indiana',
        'IOWA': 'Iowa',
        'MD': 'Maryland',
        'MICH': 'Michigan',
        'MSU': 'Michigan State',
        'MINN': 'Minnesota',
        'NEB': 'Nebraska',
        'NW': 'Northwestern',
        'OSU': 'Ohio State',
        'ORE': 'Oregon',
        'PSU': 'Penn State',
        'PUR': 'Purdue',
        'RUTG': 'Rutgers',
        'UCLA': 'UCLA',
        'USC': 'USC',
        'WASH': 'Washington',
        'WIS': 'Wisconsin',
      },
      const {
        'ILL': {'Illinois Fighting Illini'},
        'IND': {'Indiana Hoosiers'},
        'MD': {'MARY'},
        'MICH': {'Michigan Wolverines'},
        'MSU': {'Michigan State Spartans'},
        'MINN': {'MIN'},
        'NEB': {'Nebraska Cornhuskers'},
        'NW': {'Northwestern Wildcats'},
        'OSU': {'Ohio State Buckeyes', 'OHST'},
        'ORE': {'Oregon Ducks'},
        'PSU': {'Penn State Nittany Lions', 'PENNST'},
        'PUR': {'Purdue Boilermakers'},
        'RUTG': {'RUT'},
        'WASH': {'Washington Huskies', 'UW'},
        'WIS': {'Wisconsin Badgers'},
      },
    ),
    ..._conference(
      NcaafConference.big12,
      const {
        'ARIZ': 'Arizona',
        'ASU': 'Arizona State',
        'BAY': 'Baylor',
        'BYU': 'BYU',
        'CIN': 'Cincinnati',
        'COLO': 'Colorado',
        'HOU': 'Houston',
        'ISU': 'Iowa State',
        'KAN': 'Kansas',
        'KSU': 'Kansas State',
        'OKST': 'Oklahoma State',
        'TCU': 'TCU',
        'TTU': 'Texas Tech',
        'UCF': 'UCF',
        'UTAH': 'Utah',
        'WVU': 'West Virginia',
      },
      const {
        'ARIZ': {'Arizona Wildcats', 'ARI'},
        'ASU': {'Arizona State Sun Devils'},
        'BAY': {'Baylor Bears'},
        'CIN': {'Cincinnati Bearcats', 'CINCY'},
        'COLO': {'Colorado Buffaloes', 'COL'},
        'HOU': {'Houston Cougars'},
        'ISU': {'Iowa State Cyclones', 'IOWAST'},
        'KAN': {'Kansas Jayhawks', 'KU'},
        'KSU': {'Kansas State Wildcats', 'KANST'},
        'OKST': {'Oklahoma State Cowboys', 'OKLA ST'},
        'TTU': {'Texas Tech Red Raiders', 'TEXTCH'},
        'UTAH': {'Utah Utes'},
        'WVU': {'West Virginia Mountaineers'},
      },
    ),
    ..._conference(
      NcaafConference.sec,
      const {
        'ALA': 'Alabama',
        'ARK': 'Arkansas',
        'AUB': 'Auburn',
        'FLA': 'Florida',
        'UGA': 'Georgia',
        'UK': 'Kentucky',
        'LSU': 'LSU',
        'MSST': 'Mississippi State',
        'MIZ': 'Missouri',
        'OU': 'Oklahoma',
        'MISS': 'Ole Miss',
        'SC': 'South Carolina',
        'TENN': 'Tennessee',
        'TEX': 'Texas',
        'TAMU': 'Texas A&M',
        'VAN': 'Vanderbilt',
      },
      const {
        'ALA': {'Alabama Crimson Tide', 'BAMA'},
        'ARK': {'Arkansas Razorbacks'},
        'AUB': {'Auburn Tigers'},
        'FLA': {'Florida Gators', 'UF'},
        'UGA': {'Georgia Bulldogs', 'GA'},
        'UK': {'Kentucky Wildcats', 'KEN'},
        'LSU': {'LSU Tigers'},
        'MSST': {'Mississippi State Bulldogs', 'MISSST'},
        'MIZ': {'Missouri Tigers', 'MIZZOU'},
        'OU': {'Oklahoma Sooners', 'OKLA'},
        'MISS': {'Ole Miss Rebels', 'Mississippi'},
        'SC': {'South Carolina Gamecocks', 'SCAR', 'SCar'},
        'TENN': {'Tennessee Volunteers', 'Tennessee Vols'},
        'TEX': {'Texas Longhorns', 'UT'},
        'TAMU': {'Texas A&M Aggies', 'TA&M'},
        'VAN': {'Vanderbilt Commodores', 'VANDY'},
      },
    ),
  ]);

  static String? canonicalKey(String providerValue) {
    final needle = _normalize(providerValue);
    for (final team in teams) {
      if ({
        team.key,
        team.abbreviation,
        team.displayName,
        ...team.aliases,
      }.any((value) => _normalize(value) == needle)) {
        return team.key;
      }
    }
    return null;
  }

  static NcaafConference? conferenceForKey(String? key) {
    if (key == null) return null;
    for (final team in teams) {
      if (team.key == key) return team.conference;
    }
    return null;
  }

  static List<CollegeFootballTeam> _conference(
    NcaafConference conference,
    Map<String, String> values,
    Map<String, Set<String>> aliases,
  ) => [
    for (final entry in values.entries)
      CollegeFootballTeam(
        key: entry.key,
        displayName: entry.value,
        abbreviation: entry.key,
        conference: conference,
        aliases: aliases[entry.key] ?? const {},
      ),
  ];

  static String _normalize(String value) => value.trim().toUpperCase();
}
