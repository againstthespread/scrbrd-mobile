import 'package:flutter/foundation.dart';

import 'espn_data_source.dart';
import 'sports_data_io_data_source.dart';
import 'sports_repository.dart';

enum SportsDataProvider {
  sportsDataIO('SportsDataIO'),
  espn('ESPN');

  const SportsDataProvider(this.label);

  final String label;
}

SportsDataProvider selectSportsDataProvider([String? configuredValue]) {
  final value =
      configuredValue ??
      const String.fromEnvironment(
        'SPORTS_DATA_PROVIDER',
        defaultValue: 'sportsdataio',
      );
  return value.trim().toLowerCase() == 'espn'
      ? SportsDataProvider.espn
      : SportsDataProvider.sportsDataIO;
}

SportsRepository createSportsRepository({SportsDataProvider? provider}) {
  final selected = provider ?? selectSportsDataProvider();
  debugPrint('Data provider: ${selected.label}');
  return switch (selected) {
    SportsDataProvider.sportsDataIO => SportsRepository(
      SportsDataIODataSource(),
    ),
    SportsDataProvider.espn => SportsRepository(EspnDataSource()),
  };
}
