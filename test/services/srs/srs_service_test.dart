import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parley/services/srs/srs_service.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 1, 1, 12);
  late SrsService service;

  setUp(() {
    service = SrsService();
  });

  test('new card is due now with phase new', () {
    final SrsCard card = service.newCard(now);

    expect(card.phase, CardPhase.isNew);
    expect(card.due, now);
    expect(card.stability, isNull);
    expect(card.lastReview, isNull);
  });

  test('due ordering: again <= hard <= good <= easy', () {
    final SrsCard againCard = service.review(
      service.newCard(now),
      Rating.again,
      now,
    );
    final SrsCard hardCard = service.review(
      service.newCard(now),
      Rating.hard,
      now,
    );
    final SrsCard goodCard = service.review(
      service.newCard(now),
      Rating.good,
      now,
    );
    final SrsCard easyCard = service.review(
      service.newCard(now),
      Rating.easy,
      now,
    );

    expect(
      againCard.due.isBefore(hardCard.due) ||
          againCard.due.isAtSameMomentAs(hardCard.due),
      isTrue,
    );
    expect(
      hardCard.due.isBefore(goodCard.due) ||
          hardCard.due.isAtSameMomentAs(goodCard.due),
      isTrue,
    );
    expect(
      goodCard.due.isBefore(easyCard.due) ||
          goodCard.due.isAtSameMomentAs(easyCard.due),
      isTrue,
    );
    // Easy graduates to days, the rest stay in minutes.
    expect(
      easyCard.due.difference(now).inHours,
      greaterThan(goodCard.due.difference(now).inHours),
    );
  });

  test('exact due timestamps per rating (fuzzing disabled)', () {
    final SrsCard card = service.newCard(now);

    // Learning steps are 1m and 10m; easy uses the initial stability.
    expect(
      service.review(card, Rating.again, now).due,
      DateTime.utc(2026, 1, 1, 12, 1),
    );
    expect(
      service.review(card, Rating.hard, now).due,
      DateTime.utc(2026, 1, 1, 12, 5, 30),
    );
    expect(
      service.review(card, Rating.good, now).due,
      DateTime.utc(2026, 1, 1, 12, 10),
    );
    expect(
      service.review(card, Rating.easy, now).due,
      DateTime.utc(2026, 1, 17, 12),
    );
  });

  test('serialization round trip for new and reviewed cards', () {
    final SrsCard fresh = service.newCard(now);
    expect(SrsCard.fromJson(fresh.toJson()), fresh);
    expect(SrsCard.fromMap(fresh.toMap()), fresh);

    final SrsCard reviewed = service.review(fresh, Rating.good, now);
    expect(SrsCard.fromJson(reviewed.toJson()), reviewed);
    expect(SrsCard.fromMap(reviewed.toMap()), reviewed);

    // The stored string is valid JSON with the phase value.
    expect(reviewed.toJson(), contains('"phase"'));
  });

  test('int JSON numbers parse as doubles in SrsCard.fromMap (A-59)', () {
    final Map<String, dynamic> map = <String, dynamic>{
      'phase': 2,
      'due': '2026-01-01T12:00:00.000Z',
      'stability': 30,
      'lastReview': '2026-01-01T12:00:00.000Z',
      'difficulty': 5,
      'step': null,
      'cardId': 1,
    };

    final SrsCard fromMap = SrsCard.fromMap(map);
    expect(fromMap.stability, 30.0);
    expect(fromMap.difficulty, 5.0);

    // Exactly the export/import round trip: jsonDecode turns 30 into int.
    final SrsCard fromJson = SrsCard.fromJson(jsonEncode(map));
    expect(fromJson.stability, 30.0);
    expect(fromJson, fromMap);
  });

  test('non-finite stability or difficulty cannot be written to JSON', () {
    SrsCard cardWith({double? stability, double? difficulty}) => SrsCard(
      phase: CardPhase.review,
      due: now,
      stability: stability,
      lastReview: now,
      difficulty: difficulty,
      step: null,
      cardId: 1,
    );

    // JSON has no NaN/Infinity; encoding must fail loudly, not silently
    // corrupt the stored scheduling state.
    expect(
      () => cardWith(stability: double.nan, difficulty: 5.0).toJson(),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(
      () => cardWith(stability: 30.0, difficulty: double.infinity).toJson(),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
  });

  test('due and lastReview round-trip for UTC and non-UTC dates', () {
    final SrsCard localCard = SrsCard(
      phase: CardPhase.review,
      due: DateTime(2026, 3, 1, 12),
      stability: 10.5,
      lastReview: DateTime(2026, 3, 1, 12),
      difficulty: 5.0,
      step: null,
      cardId: 42,
    );
    final SrsCard localRoundTrip = SrsCard.fromJson(localCard.toJson());
    expect(localRoundTrip, localCard);
    expect(localRoundTrip.due.isUtc, isFalse);
    expect(localRoundTrip.lastReview!.isUtc, isFalse);

    final SrsCard utcCard = SrsCard(
      phase: CardPhase.review,
      due: DateTime.utc(2026, 3, 1, 12),
      stability: 10.5,
      lastReview: DateTime.utc(2026, 2, 28, 12),
      difficulty: 5.0,
      step: null,
      cardId: 42,
    );
    final SrsCard utcRoundTrip = SrsCard.fromJson(utcCard.toJson());
    expect(utcRoundTrip, utcCard);
    expect(utcRoundTrip.due.isUtc, isTrue);

    // The service always schedules in UTC, even for a local `now`.
    final DateTime localNow = DateTime(2026, 3, 1, 12);
    final SrsCard scheduled = service.review(
      service.newCard(localNow),
      Rating.good,
      localNow,
    );
    expect(scheduled.due.isUtc, isTrue);
    expect(scheduled.due, localNow.toUtc().add(const Duration(minutes: 10)));
    expect(scheduled.lastReview, localNow.toUtc());
    expect(SrsCard.fromJson(scheduled.toJson()), scheduled);
  });

  test('phase mapping covers new, learning, review and relearning', () {
    expect(service.newCard(now).phase, CardPhase.isNew);

    final SrsCard learning = service.review(
      service.newCard(now),
      Rating.again,
      now,
    );
    expect(learning.phase, CardPhase.learning);

    final SrsCard review = service.review(
      service.newCard(now),
      Rating.easy,
      now,
    );
    expect(review.phase, CardPhase.review);

    final SrsCard relearning = service.review(
      review,
      Rating.again,
      now.add(const Duration(days: 1)),
    );
    expect(relearning.phase, CardPhase.relearning);
  });

  test('review stamps lastReview and keeps the card id', () {
    final SrsCard fresh = service.newCard(now);
    final SrsCard next = service.review(fresh, Rating.good, now);

    expect(next.lastReview, now);
    expect(next.cardId, fresh.cardId);
    expect(next.stability, isNotNull);
  });

  test('Rating and CardPhase values match the SPEC columns', () {
    expect(Rating.again.value, 1);
    expect(Rating.hard.value, 2);
    expect(Rating.good.value, 3);
    expect(Rating.easy.value, 4);

    expect(CardPhase.isNew.value, 0);
    expect(CardPhase.learning.value, 1);
    expect(CardPhase.review.value, 2);
    expect(CardPhase.relearning.value, 3);

    expect(Rating.fromValue(1), Rating.again);
    expect(Rating.fromValue(4), Rating.easy);
    expect(CardPhase.fromValue(0), CardPhase.isNew);
    expect(CardPhase.fromValue(3), CardPhase.relearning);
    expect(() => Rating.fromValue(0), throwsArgumentError);
    expect(() => CardPhase.fromValue(9), throwsArgumentError);
  });
}
