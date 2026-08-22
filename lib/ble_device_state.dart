enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  sending,
  error,
}

extension BleConnectionStateSemantics on BleConnectionState {
  bool get isPhysicallyConnected =>
      this == BleConnectionState.connected ||
      this == BleConnectionState.sending;
}

class BleDeviceCandidate {
  const BleDeviceCandidate({required this.id, required this.name});

  final String id;
  final String name;
}

class BleDeviceSnapshot {
  const BleDeviceSnapshot({
    required this.state,
    this.deviceName,
    this.errorMessage,
    this.candidates = const [],
  });

  final BleConnectionState state;
  final String? deviceName;
  final String? errorMessage;
  final List<BleDeviceCandidate> candidates;

  BleDeviceSnapshot copyWith({
    BleConnectionState? state,
    String? deviceName,
    String? errorMessage,
    List<BleDeviceCandidate>? candidates,
    bool clearError = false,
  }) {
    return BleDeviceSnapshot(
      state: state ?? this.state,
      deviceName: deviceName ?? this.deviceName,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      candidates: candidates ?? this.candidates,
    );
  }
}
