import 'package:flutter_test/flutter_test.dart';
import 'package:parley/core/failures.dart';

void main() {
  test('every failure exposes its exact SPEC 5.9 message', () {
    expect(
      const OfflineFailure().userMessage,
      'This feature isn\'t available offline.',
    );
    expect(
      const NotConfiguredFailure().userMessage,
      'Set up your AI provider in Settings.',
    );
    expect(
      const AuthFailure().userMessage,
      'The API key was rejected. Check it in Settings.',
    );
    expect(
      const RateLimitFailure().userMessage,
      'Rate limit reached. Try again in a moment.',
    );
    expect(
      const ServerFailure().userMessage,
      'The AI service didn\'t respond. Try again.',
    );
    expect(
      const InvalidResponseFailure().userMessage,
      'The AI returned an unexpected response.',
    );
  });

  test('failures are AppFailures', () {
    const List<AppFailure> failures = [
      OfflineFailure(),
      NotConfiguredFailure(),
      AuthFailure(),
      RateLimitFailure(),
      ServerFailure(),
      InvalidResponseFailure(),
    ];
    expect(failures, hasLength(6));
  });
}
