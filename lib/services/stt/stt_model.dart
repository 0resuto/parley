import 'stt_engine.dart';

/// One downloadable offline speech model (SPEC 5.10).
class SttModel {
  const SttModel({
    required this.engine,
    required this.name,
    required this.description,
    required this.url,
    required this.downloadBytes,
    required this.sha256,
    required this.archiveRoot,
    required this.files,
    required this.license,
  });

  final SttEngineKind engine;
  final String name;
  final String description;
  final String url;
  final int downloadBytes;
  final String sha256;

  /// Top-level directory inside the `.tar.bz2` archive.
  final String archiveRoot;

  /// Files kept from [archiveRoot]; everything else is discarded.
  final List<String> files;

  final String license;

  /// Locale-independent size label such as `29 MB`.
  String get sizeLabel => formatModelBytes(downloadBytes);
}

/// Formats a byte count as a short binary size (MiB shown as MB).
String formatModelBytes(int bytes) {
  const int kib = 1024;
  const int mib = kib * 1024;
  const int gib = mib * 1024;
  if (bytes >= gib) {
    return '${(bytes / gib).toStringAsFixed(1)} GB';
  }
  if (bytes >= mib) {
    return '${(bytes / mib).ceil()} MB';
  }
  if (bytes >= kib) {
    return '${(bytes / kib).ceil()} kB';
  }
  return '$bytes B';
}

/// Offline models shown in Settings.
const List<SttModel> sttModels = [
  SttModel(
    engine: SttEngineKind.moonshine,
    name: 'Moonshine Tiny',
    description: 'Fast offline recognition for short messages.',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2',
    downloadBytes: 29858559,
    sha256: '9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d',
    archiveRoot: 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27',
    files: [
      'encoder_model.ort',
      'decoder_model_merged.ort',
      'tokens.txt',
      'LICENSE',
    ],
    license: 'MIT',
  ),
  SttModel(
    engine: SttEngineKind.whisper,
    name: 'Whisper Tiny.en',
    description: 'More accurate offline recognition; a larger download.',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-whisper-tiny.en.tar.bz2',
    downloadBytes: 118071777,
    sha256: '2bd6cf965c8bb3e068ef9fa2191387ee63a9dfa2a4e37582a8109641c20005dd',
    archiveRoot: 'sherpa-onnx-whisper-tiny.en',
    files: [
      'tiny.en-encoder.int8.onnx',
      'tiny.en-decoder.int8.onnx',
      'tiny.en-tokens.txt',
    ],
    license: 'MIT',
  ),
];

/// Returns the model for [engine], or null for the system engine.
SttModel? sttModelFor(SttEngineKind engine) {
  for (final SttModel model in sttModels) {
    if (model.engine == engine) {
      return model;
    }
  }
  return null;
}
