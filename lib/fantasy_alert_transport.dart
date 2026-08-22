import 'fantasy_point_alert.dart';

/// Ephemeral extension to the normal device transport; it owns no sports state.
abstract interface class FantasyAlertTransport {
  Future<void> sendFantasyAlert(FantasyPointAlert alert);
}
