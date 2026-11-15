import 'cloud_vision_hazard.dart';

const String walkingNavigationDisclaimer = '台阶和路沿不能可靠提醒，请用盲杖确认。';

/// Independent walking scan cadence. The caller owns camera and transport gates.
class WalkingHazardScan {
  WalkingHazardScan(
      {required this.scan, required this.speak, required this.gate});

  final Future<HazardScanOutcome?> Function(DateTime now) scan;
  final void Function(String text) speak;
  final CloudVisionDowngradeGate gate;
  DateTime? _lastAttempt;
  bool _inFlight = false;
  bool get inFlight => _inFlight;

  Future<void> tick(
      {required bool navigating,
      required bool walking,
      required bool busy,
      required DateTime now}) async {
    if (!navigating || !walking || busy || _inFlight) return;
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(seconds: 60)) {
      return;
    }
    _lastAttempt = now;
    _inFlight = true;
    try {
      final HazardScanOutcome? outcome = await scan(now);
      // Null means a shared rate limiter or permission gate skipped the call.
      if (outcome == null) return;
      final HazardAssessment? assessment = outcome.assessment;
      if (!outcome.ok || assessment == null || !assessment.parsed) {
        if (gate.shouldAnnounce(now)) speak(cloudVisionDowngradeSpeech);
        return;
      }
      gate.noteSuccess();
      final String? text =
          hazardGroundSpeech(assessment) ?? hazardPavingSpeech(assessment);
      if (text != null) speak(text);
    } catch (_) {
      if (gate.shouldAnnounce(now)) speak(cloudVisionDowngradeSpeech);
    } finally {
      _inFlight = false;
    }
  }
}
