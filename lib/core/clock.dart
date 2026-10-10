/// Injectable clock. Logic must use [Clock], never `DateTime.now()` directly.
abstract class Clock {
  DateTime now();
}

/// Production clock.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
