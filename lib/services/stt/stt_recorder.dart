import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Microphone capture for offline recognition.
///
/// The interface exists so unit tests can feed PCM without a platform plugin.
abstract class SttRecorder {
  Future<bool> hasPermission();

  Future<void> start();

  /// Raw 16 kHz mono PCM16 little-endian chunks.
  Stream<Uint8List> get chunks;

  /// Stops recording and waits for the stream to close.
  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();
}

/// [SttRecorder] backed by `record`.
class RecordSttRecorder implements SttRecorder {
  RecordSttRecorder([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _done;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    final Stream<Uint8List> stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        streamBufferSize: 1024,
      ),
    );
    final Completer<void> done = Completer<void>();
    _done = done;
    _subscription = stream.listen(
      _chunks.add,
      onError: (Object error, StackTrace stack) {
        _chunks.addError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete();
        }
      },
      cancelOnError: false,
    );
  }

  @override
  Stream<Uint8List> get chunks => _chunks.stream;

  @override
  Future<void> stop() async {
    await _recorder.stop();
    final Completer<void>? done = _done;
    if (done != null) {
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await _subscription?.cancel();
    _subscription = null;
    _done = null;
  }

  @override
  Future<void> cancel() async {
    try {
      await _recorder.cancel();
    } catch (_) {
      // The recorder may not be running.
    }
    await _subscription?.cancel();
    _subscription = null;
    _done = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _chunks.close();
    await _recorder.dispose();
  }
}
