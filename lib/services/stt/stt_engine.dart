/// Speech-recognition engines available in Settings (SPEC 5.10).
enum SttEngineKind {
  /// The Android system recognizer, with an optional on-device preference.
  system,

  /// The downloaded Moonshine Tiny model (fast, small).
  moonshine,

  /// The downloaded Whisper Tiny.en model (more accurate, larger).
  whisper;

  /// True when the engine needs a downloaded model.
  bool get isLocal => this != SttEngineKind.system;

  /// Stable identifier used for storage and model directories.
  String get id => name;
}
