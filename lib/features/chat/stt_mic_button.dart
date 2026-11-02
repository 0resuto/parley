import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'stt_controller.dart';

/// Microphone button that follows the live input level while listening.
///
/// The level is applied directly, without smoothing, and a gentle cyclic pulse
/// keeps the button alive between level events.
class SttMicButton extends ConsumerStatefulWidget {
  const SttMicButton({
    super.key,
    required this.isListening,
    required this.onPressed,
  });

  final bool isListening;
  final VoidCallback onPressed;

  @override
  ConsumerState<SttMicButton> createState() => _SttMicButtonState();
}

class _SttMicButtonState extends ConsumerState<SttMicButton>
    with SingleTickerProviderStateMixin {
  /// Largest size increase from the input level.
  static const double _levelGain = 0.3;

  /// Gentle breathing while listening, as a fraction of the base size.
  static const double _breathGain = 0.018;
  static const Duration _breathPeriod = Duration(milliseconds: 1400);

  late final Ticker _ticker;
  late final ProviderSubscription<AsyncValue<double>> _levelSubscription;
  final ValueNotifier<double> _scale = ValueNotifier<double>(1);
  double _level = 0;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _levelSubscription = ref.listenManual<AsyncValue<double>>(
      sttLevelProvider,
      (AsyncValue<double>? previous, AsyncValue<double> next) {
        final double? level = next.value;
        if (!widget.isListening || level == null) {
          return;
        }
        _level = level.clamp(0.0, 1.0).toDouble();
        _updateScale();
      },
    );
    if (widget.isListening) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(SttMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isListening == oldWidget.isListening) {
      return;
    }
    _level = 0;
    _elapsed = Duration.zero;
    _scale.value = 1;
    if (widget.isListening) {
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _levelSubscription.close();
    _ticker.dispose();
    _scale.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    _updateScale();
  }

  void _updateScale() {
    if (!widget.isListening) {
      _scale.value = 1;
      return;
    }
    final double phase =
        2 * math.pi * _elapsed.inMicroseconds / _breathPeriod.inMicroseconds;
    _scale.value = 1 + _levelGain * _level + _breathGain * math.sin(phase);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: _scale,
      child: IconButton(
        key: const Key('chatMicButton'),
        icon: Icon(widget.isListening ? Icons.mic : Icons.mic_none),
        style: widget.isListening
            ? IconButton.styleFrom(
                backgroundColor: colors.onSurface,
                foregroundColor: colors.surface,
              )
            : IconButton.styleFrom(
                backgroundColor: colors.surfaceContainerHigh,
                foregroundColor: colors.onSurfaceVariant,
              ),
        tooltip: widget.isListening ? 'Stop voice input' : 'Voice input',
        onPressed: widget.onPressed,
      ),
      builder: (BuildContext context, double scale, Widget? child) {
        return Transform.scale(
          key: const Key('chatMicScale'),
          scale: scale,
          child: child,
        );
      },
    );
  }
}
