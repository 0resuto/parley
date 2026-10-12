import 'dart:convert';

import 'package:fsrs/fsrs.dart' as fsrs;

/// Card phase stored in the database (SPEC 4.1).
///
/// Values match the `units.phase` column: 0 new, 1 learning, 2 review,
/// 3 relearning. The underlying `fsrs` package has no "new" state, so a
/// freshly created card is [CardPhase.isNew] and becomes learning/review/
/// relearning after its first review.
enum CardPhase {
  /// Never reviewed (SPEC 'new').
  isNew(0),

  /// First learning steps.
  learning(1),

  /// Graduated, scheduled in days.
  review(2),

  /// Lapsed from review, back in short steps.
  relearning(3);

  const CardPhase(this.value);

  final int value;

  static CardPhase fromValue(int value) {
    switch (value) {
      case 0:
        return CardPhase.isNew;
      case 1:
        return CardPhase.learning;
      case 2:
        return CardPhase.review;
      case 3:
        return CardPhase.relearning;
      default:
        throw ArgumentError('Invalid CardPhase value: $value');
    }
  }
}

/// Review rating, ints match the `reviews.rating` column (SPEC 4.1).
enum Rating {
  again(1),
  hard(2),
  good(3),
  easy(4);

  const Rating(this.value);

  final int value;

  static Rating fromValue(int value) {
    switch (value) {
      case 1:
        return Rating.again;
      case 2:
        return Rating.hard;
      case 3:
        return Rating.good;
      case 4:
        return Rating.easy;
      default:
        throw ArgumentError('Invalid Rating value: $value');
    }
  }
}

/// Scheduling state of one unit.
///
/// Thin wrapper over `fsrs.Card`: all fields needed to resume scheduling
/// are stored, so [toJson]/[fromJson] round-trips without loss. [due],
/// [stability] and [lastReview] mirror the SPEC 4.1 columns.
class SrsCard {
  const SrsCard({
    required this.phase,
    required this.due,
    required this.stability,
    required this.lastReview,
    required this.difficulty,
    required this.step,
    required this.cardId,
  });

  final CardPhase phase;
  final DateTime due;
  final double? stability;
  final DateTime? lastReview;
  final double? difficulty;
  final int? step;
  final int cardId;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'phase': phase.value,
      'due': due.toIso8601String(),
      'stability': stability,
      'lastReview': lastReview?.toIso8601String(),
      'difficulty': difficulty,
      'step': step,
      'cardId': cardId,
    };
  }

  factory SrsCard.fromMap(Map<String, dynamic> map) {
    return SrsCard(
      phase: CardPhase.fromValue(map['phase'] as int),
      due: DateTime.parse(map['due'] as String),
      // (A-59) JSON round trips may store whole numbers as int.
      stability: (map['stability'] as num?)?.toDouble(),
      lastReview: map['lastReview'] != null
          ? DateTime.parse(map['lastReview'] as String)
          : null,
      difficulty: (map['difficulty'] as num?)?.toDouble(),
      step: map['step'] as int?,
      cardId: map['cardId'] as int,
    );
  }

  /// JSON string stored in the `units.fsrs_json` column.
  String toJson() => jsonEncode(toMap());

  factory SrsCard.fromJson(String source) {
    final Map<String, dynamic> map = jsonDecode(source) as Map<String, dynamic>;
    return SrsCard.fromMap(map);
  }

  @override
  String toString() {
    return 'SrsCard(phase: $phase, due: $due, stability: $stability, '
        'lastReview: $lastReview)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SrsCard &&
        other.phase == phase &&
        other.due == due &&
        other.stability == stability &&
        other.lastReview == lastReview &&
        other.difficulty == difficulty &&
        other.step == step &&
        other.cardId == cardId;
  }

  @override
  int get hashCode {
    return Object.hash(
      phase,
      due,
      stability,
      lastReview,
      difficulty,
      step,
      cardId,
    );
  }
}

/// FSRS wrapper (PLAN 2.1).
///
/// All time comes from the caller (`now`); this class never reads the
/// system clock, so tests stay deterministic. Fuzzing is off for
/// predictable intervals.
class SrsService {
  SrsService({fsrs.Scheduler? scheduler})
    : _scheduler = scheduler ?? fsrs.Scheduler(enableFuzzing: false);

  final fsrs.Scheduler _scheduler;

  /// A card that is due immediately.
  SrsCard newCard(DateTime now) {
    final DateTime utc = now.toUtc();
    return SrsCard(
      phase: CardPhase.isNew,
      due: utc,
      stability: null,
      lastReview: null,
      difficulty: null,
      step: 0,
      cardId: utc.microsecondsSinceEpoch,
    );
  }

  /// Applies [rating] at [now] and returns the rescheduled card.
  SrsCard review(SrsCard card, Rating rating, DateTime now) {
    final DateTime utc = now.toUtc();
    final fsrs.Card fsrsCard = fsrs.Card(
      cardId: card.cardId,
      state: _toFsrsState(card.phase),
      step: card.step,
      stability: card.stability,
      difficulty: card.difficulty,
      due: card.due,
      lastReview: card.lastReview,
    );
    final ({fsrs.Card card, fsrs.ReviewLog reviewLog}) result = _scheduler
        .reviewCard(fsrsCard, _toFsrsRating(rating), reviewDateTime: utc);
    final fsrs.Card next = result.card;
    return SrsCard(
      phase: _toPhase(next.state),
      due: next.due,
      stability: next.stability,
      lastReview: next.lastReview,
      difficulty: next.difficulty,
      step: next.step,
      cardId: next.cardId,
    );
  }

  static fsrs.State _toFsrsState(CardPhase phase) {
    switch (phase) {
      case CardPhase.isNew:
      case CardPhase.learning:
        return fsrs.State.learning;
      case CardPhase.review:
        return fsrs.State.review;
      case CardPhase.relearning:
        return fsrs.State.relearning;
    }
  }

  static CardPhase _toPhase(fsrs.State state) {
    switch (state) {
      case fsrs.State.learning:
        return CardPhase.learning;
      case fsrs.State.review:
        return CardPhase.review;
      case fsrs.State.relearning:
        return CardPhase.relearning;
    }
  }

  static fsrs.Rating _toFsrsRating(Rating rating) {
    switch (rating) {
      case Rating.again:
        return fsrs.Rating.again;
      case Rating.hard:
        return fsrs.Rating.hard;
      case Rating.good:
        return fsrs.Rating.good;
      case Rating.easy:
        return fsrs.Rating.easy;
    }
  }
}
