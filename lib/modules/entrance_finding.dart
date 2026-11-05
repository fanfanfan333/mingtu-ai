/// Entrance finding for Mingtu AI v0.1.
///
/// "Map says arrived" is NOT "entrance found". An entrance is only
/// confirmed when a candidate is backed by site-verified data (not the
/// placeholder locations in lib/data) AND a high-confidence visual/OCR
/// match, AND location accuracy is good enough to be meaningful.
enum EntranceState { approaching, searching, candidateFound, confirmed, uncertain }

class EntranceCandidate {
  final String id;
  final String label;
  final double confidence; // 0..1
  final bool siteVerified; // true only for data verified on site
  const EntranceCandidate({
    required this.id,
    required this.label,
    required this.confidence,
    required this.siteVerified,
  });
}

class EntranceResult {
  final EntranceState state;
  final EntranceCandidate? candidate;
  final String reason;
  const EntranceResult(this.state, this.reason, [this.candidate]);
}

class EntranceFinding {
  EntranceResult findEntrance({
    required List<EntranceCandidate> candidates,
    required double locationAccuracyM,
  }) {
    if (locationAccuracyM > 30.0) {
      return const EntranceResult(
        EntranceState.uncertain,
        '定位精度不足，无法确认入口。',
      );
    }
    EntranceCandidate? best;
    for (final c in candidates) {
      if (c.siteVerified && c.confidence >= 0.7) {
        if (best == null || c.confidence > best.confidence) best = c;
      }
    }
    if (best != null) {
      return EntranceResult(EntranceState.confirmed, '入口已确认。', best);
    }
    final anyCandidate = candidates.isNotEmpty
        ? candidates.reduce((a, b) => a.confidence > b.confidence ? a : b)
        : null;
    if (anyCandidate != null) {
      return EntranceResult(
        EntranceState.candidateFound,
        '发现疑似入口，但未经现场核验，不能确认为正确入口。',
        anyCandidate,
      );
    }
    return const EntranceResult(
      EntranceState.searching,
      '未发现入口，继续寻找或请求帮助。',
    );
  }
}
