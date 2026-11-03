import 'dart:async';

import 'package:parley/services/stt/stt_service.dart';

/// Scriptable [SttService] for controller and widget tests.
class FakeSttService implements SttService {
  FakeSttService({this.available = true, this.startEmitsStarted = true});

  bool available;
  bool startEmitsStarted;
  final List<String> calls = [];
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();

  @override
  Future<bool> initialize() async {
    calls.add('initialize');
    return available;
  }

  @override
  Future<void> start() async {
    calls.add('start');
    if (startEmitsStarted) {
      _events.add(const SttStarted());
    }
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
  }

  @override
  Stream<SttEvent> get events => _events.stream;

  void emitStarted() => _events.add(const SttStarted());

  void emitLevel(double level) => _events.add(SttLevel(level));

  void emitSpectrum(List<double> bands) => _events.add(SttAudioSpectrum(bands));

  void emitPartial(String text) => _events.add(SttPartial(text));

  void emitFinal(String text) => _events.add(SttFinalResult(text));

  void emitStopped() => _events.add(const SttStopped());

  void emitFailure(SttFailure failure) => _events.add(SttFailed(failure));

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}
