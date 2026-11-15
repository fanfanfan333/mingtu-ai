/// Blind-path / walkable-area decision for Mingtu AI v0.1.
///
/// Blind-path priority is a preference, NOT a hard rule: if the blind
/// path ahead is blocked, the system must not keep following it.
/// "No obstacle detected" is never treated as "blind path is clear".
enum BlindPathRecommendation { continueOnBlindPath, stopAndAskHelp, uncertain }

class BlindPathAssessment {
  final BlindPathRecommendation recommendation;
  final String speechText;
  final String reason;
  const BlindPathAssessment(this.recommendation, this.speechText, this.reason);
}

class BlindPathService {
  BlindPathAssessment assess({
    required bool blindPathVisible,
    required bool blocked,
    required bool alternativeConfirmed,
    required bool alternativeSideKnown,
  }) {
    if (!blindPathVisible) {
      return const BlindPathAssessment(
        BlindPathRecommendation.uncertain,
        '盲道情况无法确认，请停下并谨慎判断。',
        'blind-path-not-visible',
      );
    }
    if (!blocked) {
      return const BlindPathAssessment(
        BlindPathRecommendation.continueOnBlindPath,
        '继续沿当前路线前进。',
        'blind-path-not-blocked-in-this-frame-only',
      );
    }
    // A blocked path requires stopping regardless of alternative reports.
    return const BlindPathAssessment(
      BlindPathRecommendation.stopAndAskHelp,
      '前方盲道被占用，请停下，用盲杖确认。',
      'blind-path-blocked',
    );
  }
}
