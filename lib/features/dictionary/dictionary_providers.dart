import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart';
import 'package:parley/data/repositories/unit_repository.dart';

/// Injectable clock for dictionary UI (relative due dates).
final clockProvider = Provider<Clock>((ref) => const SystemClock());

/// Builds the dictionary repository from the app database and clock.
///
/// Tests override this (or [appDatabaseProvider] and [clockProvider])
/// with an in-memory database and a fake clock.
final unitRepositoryProvider = Provider<UnitRepository>((ref) {
  final AppDatabase db = ref.watch(appDatabaseProvider);
  final Clock clock = ref.watch(clockProvider);
  return UnitRepository(db, clock: clock);
});
