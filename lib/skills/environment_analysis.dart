/// Skill: environment_analysis (v0.1, IMPLEMENTED as risk assessment
/// over perception events).
///
/// It never invents a step direction: if the risk engine says the side
/// is uncertain, the skill returns the cautious prompt unchanged.
library;

import '../core/risk_engine.dart';

class EnvironmentAnalysisResult {
  final RiskAssessment assessment;
  const EnvironmentAnalysisResult(this.assessment);
}

class EnvironmentAnalysisSkill {
  final RiskEngine riskEngine;
  EnvironmentAnalysisSkill([RiskEngine? engine]) : riskEngine = engine ?? RiskEngine();

  EnvironmentAnalysisResult analyse(RiskEvent event, DateTime now) {
    return EnvironmentAnalysisResult(riskEngine.assess(event, now));
  }
}
