import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:parley/core/failures.dart';

/// Network connectivity (SPEC 5.9, background tutor jobs).
///
/// Online-only actions call [requireOnline] first; it throws
/// [OfflineFailure] when there is no connection.
abstract class ConnectivityService {
  /// True when the device currently has a network connection.
  Future<bool> isOnline();

  /// Emits the online state whenever connectivity changes.
  Stream<bool> get onlineStream;

  /// Throws [OfflineFailure] when the device is offline.
  Future<void> requireOnline();
}

/// [ConnectivityService] backed by `connectivity_plus`.
class ConnectivityPlusService implements ConnectivityService {
  ConnectivityPlusService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// Maps raw `connectivity_plus` results to a single online flag.
  ///
  /// An offline device yields `[ConnectivityResult.none]` (and only then);
  /// an empty list is also treated as offline.
  static bool resultsAreOnline(List<ConnectivityResult> results) {
    if (results.isEmpty) {
      return false;
    }
    return results.any((result) => result != ConnectivityResult.none);
  }

  @override
  Future<bool> isOnline() async {
    final List<ConnectivityResult> results = await _connectivity
        .checkConnectivity();
    return resultsAreOnline(results);
  }

  @override
  Stream<bool> get onlineStream =>
      _connectivity.onConnectivityChanged.map(resultsAreOnline).distinct();

  @override
  Future<void> requireOnline() async {
    if (!await isOnline()) {
      throw const OfflineFailure();
    }
  }
}
