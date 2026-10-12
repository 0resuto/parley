import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parley/core/clock.dart';
import 'package:parley/core/constants.dart';
import 'package:parley/data/db/database.dart' as db;
import 'package:parley/data/models/unit.dart';
import 'package:parley/features/dictionary/dictionary_providers.dart';
import 'package:parley/services/srs/review_service.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Tap-as-Again policy (PLAN 7.2, SPEC 5.5).
///
/// When the word popup opens on a non-Known dictionary unit, the open
/// counts as a `tap` review with rating [Rating.again], at most once per
/// [tapAgainMinGap] (24 h) per unit. Known units never rate. Failures are
/// caught and logged, never thrown, so the popup stays best-effort.
class TapAgainPolicy {
  TapAgainPolicy({
    required db.AppDatabase db,
    required ReviewService reviews,
    required Clock clock,
  }) : _db = db,
       _reviews = reviews,
       _clock = clock;

  final db.AppDatabase _db;
  final ReviewService _reviews;
  final Clock _clock;

  /// Rates [unit] with Again/source tap unless skipped.
  ///
  /// Returns true when a review was written, false when skipped
  /// (Known, recent tap review, missing unit, or failure).
  Future<bool> maybeRate(Unit unit) async {
    try {
      if (unit.knownManual) {
        return false;
      }
      final DateTime now = _clock.now().toUtc();
      final DateTime cutoff = now.subtract(tapAgainMinGap);
      if (await _hasRecentTap(unit.id, cutoff)) {
        return false;
      }
      final Unit? updated = await _reviews.rate(
        unit.id,
        Rating.again,
        ReviewSource.tap,
      );
      return updated != null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('tap-as-again failed: $e');
      }
      return false;
    }
  }

  /// True when the unit has a `tap` review at or after [cutoff].
  Future<bool> _hasRecentTap(int unitId, DateTime cutoff) async {
    final List<db.Review> rows =
        await (_db.select(_db.reviews)..where(
              (t) =>
                  t.unitId.equals(unitId) &
                  t.source.equals(ReviewSource.tap.value),
            ))
            .get();
    for (final db.Review row in rows) {
      if (!row.reviewedAt.toUtc().isBefore(cutoff)) {
        return true;
      }
    }
    return false;
  }
}

/// Provider for the tap-as-Again policy.
final tapAgainPolicyProvider = Provider<TapAgainPolicy>((ref) {
  final db.AppDatabase database = ref.watch(db.appDatabaseProvider);
  final Clock clock = ref.watch(clockProvider);
  return TapAgainPolicy(
    db: database,
    reviews: ReviewService(
      database,
      units: ref.watch(unitRepositoryProvider),
      clock: clock,
    ),
    clock: clock,
  );
});
