/// Speech-to-text stub (SPEC 2, SPEC 5.8, PLAN 8.3).
///
/// Voice input is out of v1 scope. This empty interface reserves the API
/// surface for the future; there is no implementation and nothing uses it yet.
abstract class SttService {
  /// Starts listening for voice input.
  Future<void> start();

  /// Stops listening for voice input.
  Future<void> stop();

  /// Partial recognition results as they arrive.
  Stream<String> get partials;
}
