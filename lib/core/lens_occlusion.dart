/// Cheap statistics for an 8-bit grayscale frame.
class LumaStats {
  const LumaStats(this.mean, this.variance);
  final double mean;
  final double variance;

  /// Samples at most roughly 1024 pixels, without decoding an image.
  static LumaStats fromGray(List<int> pixels) {
    if (pixels.isEmpty) throw ArgumentError('Empty grayscale frame');
    final int stride = (pixels.length / 1024).ceil();
    double sum = 0;
    double squares = 0;
    int count = 0;
    for (int i = 0; i < pixels.length; i += stride) {
      final int value = pixels[i];
      sum += value;
      squares += value * value;
      count++;
    }
    final double mean = sum / count;
    return LumaStats(
        mean, (squares / count - mean * mean).clamp(0, double.infinity));
  }
}


/// Production and test seam: push a detection-time grayscale
/// buffer into the active app monitor when one is registered.
void Function(LumaStats stats)? mingtuLensSampleSink;

void submitDetectionGrayFrame(List<int> pixels) {
  if (pixels.isEmpty) return;
  mingtuLensSampleSink?.call(LumaStats.fromGray(pixels));
}

enum LensNotice { alert, recovery }

class LensOcclusionMonitor {
  LensOcclusionMonitor({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String alertText = '镜头可能被挡住或太暗，本地检测暂时不可靠';
  static const String recoveryText = '镜头已恢复。';
  // Luma is 0..255; variance is in squared luma units.
  static const double darkMean = 20;
  static const double uniformVariance = 25;
  static const Duration persistence = Duration(seconds: 2);
  static const Duration cooldown = Duration(seconds: 25);
  // A missing stream cannot establish continuous evidence.
  static const Duration maxSampleGap = Duration(milliseconds: 1500);

  final DateTime Function() _now;
  DateTime? _anomalySince;
  DateTime? _lastSample;
  DateTime? _lastAlert;
  bool _latched = false;

  LensNotice? sample(LumaStats stats) {
    final DateTime now = _now();
    final DateTime? previous = _lastSample;
    _lastSample = now;
    if (previous != null &&
        (now.isBefore(previous) || now.difference(previous) > maxSampleGap)) {
      _anomalySince = null;
    }
    if (stats.mean >= darkMean && stats.variance >= uniformVariance) {
      _anomalySince = null;
      if (_latched) {
        _latched = false;
        return LensNotice.recovery;
      }
      return null;
    }
    _anomalySince ??= now;
    if (!_latched &&
        now.difference(_anomalySince!) >= persistence &&
        (_lastAlert == null || now.difference(_lastAlert!) >= cooldown)) {
      _latched = true;
      _lastAlert = now;
      return LensNotice.alert;
    }
    return null;
  }
}
