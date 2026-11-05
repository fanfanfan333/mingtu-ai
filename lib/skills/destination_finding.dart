/// Skill: destination_finding (v0.1, IMPLEMENTED as entrance finding).
/// See entrance_finding.dart for the confirmation rule: placeholder
/// (unverified) data alone can never confirm an entrance.
library;

import '../modules/entrance_finding.dart';

class DestinationFindingSkill {
  final EntranceFinding finding;
  DestinationFindingSkill([EntranceFinding? f]) : finding = f ?? EntranceFinding();

  EntranceResult find({
    required List<EntranceCandidate> candidates,
    required double locationAccuracyM,
  }) =>
      finding.findEntrance(
        candidates: candidates,
        locationAccuracyM: locationAccuracyM,
      );
}
