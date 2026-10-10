import 'package:parley/core/clock.dart';
import 'package:parley/data/db/database.dart' as db;
import 'package:parley/data/models/unit.dart';
import 'package:parley/data/repositories/unit_repository.dart';
import 'package:parley/services/srs/srs_service.dart';

/// Where a review came from (SPEC 4.1 `reviews.source` column).
enum ReviewSource {
  /// User rated a flashcard.
  card('card'),

  /// Background word judge rated from chat.
  chat('chat'),

  /// User tapped a word in chat.
  tap('tap');

  const ReviewSource(this.value);

  final String value;

  static ReviewSource fromValue(String value) {
    switch (value) {
      case 'card':
        return ReviewSource.card;
      case 'chat':
        return ReviewSource.chat;
      case 'tap':
        return ReviewSource.tap;
      default:
        throw ArgumentError('Invalid ReviewSource value: $value');
    }
  }
}

/// Applies FSRS reviews and records them (PLAN 2.3).
///
/// Time comes from [Clock] unless [rate] gets an explicit `at`, so tests
/// stay deterministic. Rating a missing or Known unit is ignored (returns
/// null, writes nothing).
class ReviewService {
  ReviewService(
    this._db, {
    required UnitRepository units,
    required Clock clock,
    SrsService? srs,
  }) : _units = units,
       _clock = clock,
       _srs = srs ?? SrsService();

  final db.AppDatabase _db;
  final UnitRepository _units;
  final Clock _clock;
  final SrsService _srs;

  /// Rates [unitId] with [rating] from [source].
  ///
  /// Returns the updated unit, or null when the unit is missing or Known.
  Future<Unit?> rate(
    int unitId,
    Rating rating,
    ReviewSource source, {
    DateTime? at,
  }) async {
    final Unit? unit = await _units.getById(unitId);
    if (unit == null) {
      return null;
    }
    if (unit.knownManual) {
      return null;
    }
    final DateTime now = (at ?? _clock.now()).toUtc();
    final SrsCard current = SrsCard.fromJson(unit.fsrsJson);
    final SrsCard next = _srs.review(current, rating, now);
    final Unit updated = await _units.update(
      unit.copyWith(
        phase: next.phase,
        due: next.due,
        stability: next.stability,
        fsrsJson: next.toJson(),
        lastReview: now,
      ),
    );
    await _db
        .into(_db.reviews)
        .insert(
          db.ReviewsCompanion.insert(
            unitId: unitId,
            rating: rating.value,
            source: source.value,
            reviewedAt: now,
          ),
        );
    return updated;
  }
}
