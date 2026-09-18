import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ESPN account cookies. Never interpolate this object into diagnostics.
class EspnFantasyCredentials {
  const EspnFantasyCredentials({required this.swid, required this.espnS2});
  final String swid;
  final String espnS2;

  bool get isValid => _validCookieValue(swid) && _validCookieValue(espnS2);

  @override
  String toString() => 'EspnFantasyCredentials(<redacted>)';
}

bool _validCookieValue(String value) =>
    value.trim().isNotEmpty && !value.contains(RegExp(r'[;\r\n\x00-\x1f\x7f]'));

class EspnCredentialsException implements Exception {
  const EspnCredentialsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Small adapter so tests and clients never depend on a Keychain plugin.
abstract interface class SecureStringStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecureStringStorage implements SecureStringStorage {
  DeviceSecureStringStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

abstract interface class EspnFantasyCredentialsStore {
  Future<EspnFantasyCredentials?> read();
  Future<void> save(EspnFantasyCredentials credentials);
  Future<void> clear();
  Future<bool> hasCredentials();
}

class SecureEspnFantasyCredentialsStore implements EspnFantasyCredentialsStore {
  SecureEspnFantasyCredentialsStore({SecureStringStorage? storage})
    : _storage = storage ?? DeviceSecureStringStorage();

  static const _key = 'espn_fantasy_credentials_v1';
  final SecureStringStorage _storage;

  @override
  Future<EspnFantasyCredentials?> read() async {
    try {
      final raw = await _storage.read(_key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['swid'] is! String ||
          decoded['espnS2'] is! String) {
        throw const EspnCredentialsException(
          'Saved ESPN credentials are unavailable.',
        );
      }
      final credentials = EspnFantasyCredentials(
        swid: decoded['swid'] as String,
        espnS2: decoded['espnS2'] as String,
      );
      if (!credentials.isValid) {
        throw const EspnCredentialsException(
          'Saved ESPN credentials are unavailable.',
        );
      }
      return credentials;
    } on EspnCredentialsException {
      rethrow;
    } on Object {
      // Secure storage and JSON errors may include secret values; discard detail.
      throw const EspnCredentialsException('Could not read ESPN credentials.');
    }
  }

  @override
  Future<void> save(EspnFantasyCredentials credentials) async {
    if (!credentials.isValid) {
      throw const EspnCredentialsException('Enter valid ESPN credentials.');
    }
    try {
      // A single secure value avoids a partially updated cookie pair.
      await _storage.write(
        _key,
        jsonEncode({'swid': credentials.swid, 'espnS2': credentials.espnS2}),
      );
    } on Object {
      throw const EspnCredentialsException('Could not save ESPN credentials.');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(_key);
    } on Object {
      throw const EspnCredentialsException('Could not clear ESPN credentials.');
    }
  }

  @override
  Future<bool> hasCredentials() async => (await read()) != null;
}
