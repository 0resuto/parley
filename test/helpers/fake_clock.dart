import 'package:parley/core/clock.dart';

/// Controllable clock for tests.
class FakeClock implements Clock {
  FakeClock(DateTime initial) : _now = initial;

  DateTime _now;

  @override
  DateTime now() => _now;

  void setNow(DateTime value) {
    _now = value;
  }

  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}
