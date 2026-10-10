import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';
import 'package:parley/services/connectivity/connectivity_service.dart';

import '../../helpers/fake_connectivity_service.dart';

void main() {
  group('FakeConnectivityService', () {
    test('isOnline reflects the configured state', () async {
      final online = FakeConnectivityService(online: true);
      final offline = FakeConnectivityService(online: false);
      expect(await online.isOnline(), isTrue);
      expect(await offline.isOnline(), isFalse);
      await online.dispose();
      await offline.dispose();
    });

    test('requireOnline passes when online', () async {
      final connectivity = FakeConnectivityService(online: true);
      await connectivity.requireOnline();
      await connectivity.dispose();
    });

    test('requireOnline throws OfflineFailure when offline', () async {
      final connectivity = FakeConnectivityService(online: false);
      expect(
        connectivity.requireOnline,
        throwsA(
          isA<OfflineFailure>().having(
            (failure) => failure.userMessage,
            'userMessage',
            'This feature isn\'t available offline.',
          ),
        ),
      );
      await connectivity.dispose();
    });

    test('onlineStream emits changes', () async {
      final connectivity = FakeConnectivityService(online: true);
      final List<bool> events = [];
      final subscription = connectivity.onlineStream.listen(events.add);
      connectivity.setOnline(false);
      connectivity.setOnline(true);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(events, [false, true]);
      expect(await connectivity.isOnline(), isTrue);
      await connectivity.dispose();
    });
  });

  group('ConnectivityPlusService.resultsAreOnline', () {
    test('maps connectivity results to the online state', () {
      expect(
        ConnectivityPlusService.resultsAreOnline([ConnectivityResult.none]),
        isFalse,
      );
      expect(
        ConnectivityPlusService.resultsAreOnline([ConnectivityResult.wifi]),
        isTrue,
      );
      expect(
        ConnectivityPlusService.resultsAreOnline([ConnectivityResult.mobile]),
        isTrue,
      );
      expect(ConnectivityPlusService.resultsAreOnline([]), isFalse);
      expect(
        ConnectivityPlusService.resultsAreOnline([
          ConnectivityResult.none,
          ConnectivityResult.wifi,
        ]),
        isTrue,
      );
    });
  });
}
