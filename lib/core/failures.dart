/// Failures with user-visible messages (SPEC 5.9).
sealed class AppFailure implements Exception {
  const AppFailure();

  /// Exact English text shown to the user.
  String get userMessage;
}

/// Online-only action attempted while offline.
final class OfflineFailure extends AppFailure {
  const OfflineFailure();

  @override
  String get userMessage => 'This feature isn\'t available offline.';
}

/// No URL / key / model configured.
final class NotConfiguredFailure extends AppFailure {
  const NotConfiguredFailure();

  @override
  String get userMessage => 'Set up your AI provider in Settings.';
}

/// HTTP 401 / 403.
final class AuthFailure extends AppFailure {
  const AuthFailure();

  @override
  String get userMessage => 'The API key was rejected. Check it in Settings.';
}

/// HTTP 429 after retries.
final class RateLimitFailure extends AppFailure {
  const RateLimitFailure();

  @override
  String get userMessage => 'Rate limit reached. Try again in a moment.';
}

/// HTTP 5xx or network error after retries.
final class ServerFailure extends AppFailure {
  const ServerFailure();

  @override
  String get userMessage => 'The AI service didn\'t respond. Try again.';
}

/// Unparseable LLM response.
final class InvalidResponseFailure extends AppFailure {
  const InvalidResponseFailure();

  @override
  String get userMessage => 'The AI returned an unexpected response.';
}
