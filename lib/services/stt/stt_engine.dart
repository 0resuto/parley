/// Speech-recognition engines available in Settings (SPEC 5.10).
enum SttEngineKind {
  /// The Moonshine Tiny model (fast, small download).
  moonshine,

  /// The preinstalled Whisper Tiny.en model (best quality).
  whisper;

  /// Stable identifier used for storage and model directories.
  String get id => name;
}
