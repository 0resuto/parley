import 'dart:async';
import 'dart:isolate';

import 'import_worker.dart';

/// Runs import jobs (SPEC 5.12).
///
/// Behind an interface so tests can run the worker inline while the app
/// uses a background isolate.
abstract class DictionaryImportRunner {
  /// Runs one import job. While a job is running, a second [run] is
  /// rejected with an immediate failure outcome (A-15) instead of
  /// clobbering the running job's state.
  Future<ImportOutcome> run(
    ImportRequest request, {
    void Function(DictionaryImportProgress)? onProgress,
  });

  /// Aborts the running job; a pending [run] completes with
  /// [ImportOutcomeKind.cancelled].
  void cancel();
}

/// Production runner: the worker runs in a background isolate, so large
/// imports never block the UI; [cancel] kills the isolate.
class IsolateImportRunner implements DictionaryImportRunner {
  Isolate? _isolate;
  ReceivePort? _port;
  Completer<ImportOutcome>? _pending;

  @override
  Future<ImportOutcome> run(
    ImportRequest request, {
    void Function(DictionaryImportProgress)? onProgress,
  }) async {
    if (_pending != null) {
      // Overwriting the port/completer would hang the first future
      // forever and mix up both jobs' messages (A-15).
      return const ImportOutcome.failure('Import already running.');
    }
    final ReceivePort port = ReceivePort();
    final Completer<ImportOutcome> completer = Completer<ImportOutcome>();
    _port = port;
    _pending = completer;
    port.listen((Object? message) {
      if (message is DictionaryImportProgress) {
        onProgress?.call(message);
        return;
      }
      if (message is ImportOutcome) {
        _complete(message);
        return;
      }
      // A null message is the exit event: the isolate died without an
      // outcome (crash, kill, out of memory).
      _complete(const ImportOutcome.failure('Import failed.'));
    });
    // Spawn barrier (A-40): a cancel() issued right after this call wins
    // before any isolate exists, so nothing can outlive the cancellation.
    await Future<void>.delayed(Duration.zero);
    if (_pending != completer) {
      // Cancelled (or superseded) while starting: no isolate was spawned.
      return completer.future;
    }
    Isolate.spawn(
          _importIsolateMain,
          <Object?>[port.sendPort, request],
          onExit: port.sendPort,
          errorsAreFatal: true,
        )
        .then((Isolate isolate) {
          if (_pending != completer) {
            // The job was cancelled (or finished) while the isolate was
            // starting, or a newer job took over; do not leak it.
            isolate.kill(priority: Isolate.immediate);
            return;
          }
          _isolate = isolate;
        })
        .catchError((Object _) {
          if (_pending != completer) {
            return;
          }
          _complete(const ImportOutcome.failure('Import failed.'));
        });
    return completer.future;
  }

  void _complete(ImportOutcome outcome) {
    final Completer<ImportOutcome>? pending = _pending;
    _pending = null;
    _port?.close();
    _port = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(outcome);
    }
  }

  @override
  void cancel() {
    final Completer<ImportOutcome>? pending = _pending;
    if (pending == null || pending.isCompleted) {
      return;
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _pending = null;
    _port?.close();
    _port = null;
    pending.complete(const ImportOutcome.cancelled());
  }
}

void _importIsolateMain(List<Object?> args) async {
  final SendPort port = args[0]! as SendPort;
  final ImportRequest request = args[1]! as ImportRequest;
  final ImportOutcome outcome = await runDictionaryImport(
    request,
    onProgress: port.send,
  );
  port.send(outcome);
}
