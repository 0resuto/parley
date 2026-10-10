import 'dart:async';

import 'package:parley/core/failures.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';

/// Controllable [ConnectivityService] for tests.
///
/// Flip [online] via [setOnline] to simulate going offline and back.
/// [onlineStream] mirrors `connectivity_plus` semantics: it only emits
/// changes, so listeners call [isOnline] for the current state.
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService({bool online = true}) : _online = online;

  bool _online;

  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  /// Current online state returned by [isOnline].
  bool get online => _online;

  /// Sets the online state and emits it on [onlineStream].
  void setOnline(bool value) {
    _online = value;
    _controller.add(value);
  }

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get onlineStream => _controller.stream;

  @override
  Future<void> requireOnline() async {
    if (!await isOnline()) {
      throw const OfflineFailure();
    }
  }

  /// Closes the underlying stream controller.
  Future<void> dispose() => _controller.close();
}
