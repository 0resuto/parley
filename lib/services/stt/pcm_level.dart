import 'dart:math' as math;
import 'dart:typed_data';

/// Level of a PCM16 chunk in dBFS, normalized to 0..1 over -50..0 dBFS.
///
/// A dB scale keeps normal speech in the middle of the range; linear RMS
/// saturates as soon as the microphone applies any gain.
double pcm16Level(Uint8List bytes) {
  if (bytes.length < 2) {
    return 0;
  }
  final ByteData data = ByteData.sublistView(bytes);
  double sum = 0;
  int count = 0;
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    final double sample = data.getInt16(i, Endian.little) / 32768.0;
    sum += sample * sample;
    count++;
  }
  if (count == 0) {
    return 0;
  }
  final double rms = math.sqrt(sum / count);
  if (rms <= 0) {
    return 0;
  }
  final double db = 20 * math.log(rms) / math.ln10;
  return ((db + 50) / 50).clamp(0.0, 1.0).toDouble();
}
