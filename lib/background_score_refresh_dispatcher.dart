import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

// TEMPORARY EVENT-DRIVEN BACKGROUND SCORE PROTOTYPE: Remove or refactor later.
class BackgroundScoreRefreshDispatcher {
  BackgroundScoreRefreshDispatcher._();

  static const _portName = 'scrbrd_background_score_refresh';
  static const _scoreRefreshEvent = 'score_refresh';
  static final instance = BackgroundScoreRefreshDispatcher._();

  final _events = StreamController<BackgroundScoreRefreshRequest>.broadcast();
  ReceivePort? _receivePort;
  StreamSubscription<Object?>? _receiveSubscription;

  Stream<BackgroundScoreRefreshRequest> get events => _events.stream;

  void initializeMainIsolate() {
    _receiveSubscription?.cancel();
    _receivePort?.close();
    IsolateNameServer.removePortNameMapping(_portName);

    final receivePort = ReceivePort();
    _receivePort = receivePort;
    IsolateNameServer.registerPortWithName(receivePort.sendPort, _portName);
    _receiveSubscription = receivePort.listen((message) {
      if (message is List<Object?> &&
          message.length == 2 &&
          message.first == _scoreRefreshEvent &&
          message.last is SendPort) {
        _events.add(BackgroundScoreRefreshRequest._(message.last! as SendPort));
      }
    });
  }

  static Future<bool> dispatchScoreRefreshToMainIsolate() async {
    final sendPort = IsolateNameServer.lookupPortByName(_portName);
    if (sendPort == null) {
      return false;
    }

    final completionPort = ReceivePort();
    sendPort.send([_scoreRefreshEvent, completionPort.sendPort]);
    try {
      return await completionPort.first
          .timeout(const Duration(seconds: 25), onTimeout: () => false)
          .then((value) => value == true);
    } finally {
      completionPort.close();
    }
  }
}

// TEMPORARY EVENT-DRIVEN BACKGROUND SCORE PROTOTYPE: Remove or refactor later.
class BackgroundScoreRefreshRequest {
  BackgroundScoreRefreshRequest._(this._completionPort);

  final SendPort _completionPort;

  void complete() {
    _completionPort.send(true);
  }
}
