import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'stt_controller.dart';

/// Full-width, mirrored live spectrum shown while recording.
class SttSpectrum extends ConsumerStatefulWidget {
  const SttSpectrum({super.key});

  @override
  ConsumerState<SttSpectrum> createState() => _SttSpectrumState();
}

class _SttSpectrumState extends ConsumerState<SttSpectrum> {
  static const int _barCount = 32;
  final List<double> _levels = List<double>.filled(
    _barCount,
    0.04,
    growable: true,
  );

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<double>>>(sttSpectrumProvider, (
      AsyncValue<List<double>>? previous,
      AsyncValue<List<double>> next,
    ) {
      final List<double>? bands = next.value;
      if (bands == null || bands.isEmpty || !mounted) {
        return;
      }
      final List<double> target = _resample(bands, _barCount);
      const double maxBand = 0.9;
      final double rawPeak = target.reduce(
        (double a, double b) => a > b ? a : b,
      );
      // Scale the whole spectrum instead of clipping the loudest bar, so the
      // shape is preserved when the voice gets loud.
      final double scale = rawPeak > maxBand ? maxBand / rawPeak : 1;
      final double peak = rawPeak * scale;
      setState(() {
        for (int i = 0; i < _levels.length; i++) {
          final double band = target[i] * scale;
          // The peak adds a small shared pulse while the band keeps its shape.
          final double value = (peak * 0.08 + band * 0.92)
              .clamp(0.02, maxBand)
              .toDouble();
          _levels[i] = value > _levels[i]
              ? value
              : (_levels[i] * 0.6 + value * 0.4);
        }
      });
    });
    return SizedBox(
      key: const Key('chatSpectrum'),
      height: 44,
      width: double.infinity,
      child: CustomPaint(painter: _SpectrumPainter(List<double>.of(_levels))),
    );
  }

  List<double> _resample(List<double> input, int count) {
    final List<double> output = List<double>.filled(count, 0);
    if (input.length == 1) {
      return List<double>.filled(count, input.first);
    }
    for (int i = 0; i < count; i++) {
      final double position = i / (count - 1) * (input.length - 1);
      final int lower = position.floor();
      final int upper = position.ceil();
      final double fraction = position - lower;
      output[i] = input[lower] * (1 - fraction) + input[upper] * fraction;
    }
    return output;
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.bands);

  final List<double> bands;

  @override
  void paint(Canvas canvas, Size size) {
    if (bands.isEmpty || size.width <= 0) {
      return;
    }
    const Color lightGray = Color(0xFFD2D6DC);
    final double slot = size.width / bands.length;
    final double barWidth = slot * 0.68;
    final Rect rect = Offset.zero & size;

    final Paint glow = Paint()
      ..color = lightGray.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    for (int i = 0; i < bands.length; i++) {
      final double height = 3 + bands[i] * (size.height - 6);
      final double x = i * slot + (slot - barWidth) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        glow,
      );
    }

    final Paint fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: <Color>[
          lightGray.withValues(alpha: 0.22),
          lightGray.withValues(alpha: 0.9),
        ],
      ).createShader(rect);
    for (int i = 0; i < bands.length; i++) {
      final double height = 3 + bands[i] * (size.height - 6);
      final double x = i * slot + (slot - barWidth) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) => true;
}
