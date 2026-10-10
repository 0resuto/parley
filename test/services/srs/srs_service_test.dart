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
