import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class SportsHubBleProtocol {
  const SportsHubBleProtocol();

  static const advertisingName = 'Peter Sports Hub';
  static const serviceUuidText = 'd8f6a9b0-7a5e-4e8c-9f2a-2b2f5b6c1001';
  static const writableCharacteristicUuidText =
      'd8f6a9b1-7a5e-4e8c-9f2a-2b2f5b6c1001';
  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  static const wakeCharacteristicUuidText =
      'd8f6a9b2-7a5e-4e8c-9f2a-2b2f5b6c1001';

  Uuid get serviceUuid => _parseUuid('service UUID', serviceUuidText);

  Uuid get writableCharacteristicUuid => _parseUuid(
    'writable characteristic UUID',
    writableCharacteristicUuidText,
  );

  // TEMPORARY BLE WAKE-NOTIFICATION EXPERIMENT: Remove after iOS testing.
  Uuid get wakeCharacteristicUuid =>
      _parseUuid('wake characteristic UUID', wakeCharacteristicUuidText);

  Uuid _parseUuid(String label, String value) {
    final normalizedValue = value.trim().replaceAll(RegExp(r'[<>]'), '');

    if (normalizedValue.isEmpty || normalizedValue.contains('EXISTING ESP32')) {
      throw StateError(
        'Sports Hub $label is still a placeholder in SPORTS_HUB_PROTOCOL.md.',
      );
    }

    try {
      return Uuid.parse(normalizedValue);
    } on Object {
      throw StateError('Sports Hub $label is not a valid UUID.');
    }
  }
}
