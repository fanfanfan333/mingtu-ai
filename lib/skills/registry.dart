/// Unified Skill registry for Mingtu AI (refactor phase 1).
///
/// Per spec section 9: a Skill is not a prompt collection. It has an
/// id, version, scene, inputs, outputs, preconditions, required
/// modules, permissions, risk level, timeout, failure handling and
/// validation -- and it must never skip the risk engine. High-risk
/// skills additionally require an explicit risk-ok flag from the
/// caller; the registry refuses them otherwise.
///
/// Maturity is honest by construction: `notStarted` and `implemented`
/// are never upgraded to `tested` or `fieldValidated` by registration.
library;

import '../core/risk_engine.dart';

enum SkillMaturity { notStarted, implemented, tested, fieldValidated }

enum SkillExecutionStatus { ok, denied, failed }

class SkillDefinition {
  final String id;
  final String name;
  final String version;
  final String scene;
  final List<String> inputs;
  final List<String> outputs;
  final List<String> preconditions;
  final List<String> requiredModules;
  final List<String> permissions;
  final RiskLevel riskLevel;
  final SkillMaturity maturity;
  final bool enabledByDefault;

  const SkillDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.scene,
    this.inputs = const [],
    this.outputs = const [],
    this.preconditions = const [],
    this.requiredModules = const [],
    this.permissions = const [],
    required this.riskLevel,
    required this.maturity,
    this.enabledByDefault = true,
  });
}

class SkillExecutionResult {
  final String skillId;
  final SkillExecutionStatus status;
  final String reason;
  final Map<String, Object?>? output;
  const SkillExecutionResult({
    required this.skillId,
    required this.status,
    required this.reason,
    this.output,
  });
}

typedef SkillRunner = Map<String, Object?> Function();

class SkillRegistry {
  final Map<String, SkillDefinition> _definitions = {};
  final Set<String> _disabled = {};

  void register(SkillDefinition definition) {
    _definitions[definition.id] = definition;
    if (!definition.enabledByDefault) _disabled.add(definition.id);
  }

  SkillDefinition? get(String id) => _definitions[id];

  List<SkillDefinition> list() => List.unmodifiable(_definitions.values);

  void enable(String id) => _disabled.remove(id);

  void disable(String id) => _disabled.add(id);

  bool isEnabled(String id) =>
      _definitions.containsKey(id) && !_disabled.contains(id);

  /// Unified execution flow: check registration, enablement,
  /// preconditions, then (for R3/R4) risk-ok, then run. Any failure
  /// returns a denied/failed result instead of throwing into a caller
  /// that might treat an exception as success.
  SkillExecutionResult execute(
    String id, {
    required bool preconditionsMet,
    required bool riskOk,
    required SkillRunner runner,
  }) {
    final definition = _definitions[id];
    if (definition == null) {
      return SkillExecutionResult(
        skillId: id,
        status: SkillExecutionStatus.denied,
        reason: 'skill not registered',
      );
    }
    if (!isEnabled(id)) {
      return SkillExecutionResult(
        skillId: id,
        status: SkillExecutionStatus.denied,
        reason: 'skill disabled',
      );
    }
    if (!preconditionsMet) {
      return SkillExecutionResult(
        skillId: id,
        status: SkillExecutionStatus.denied,
        reason: 'preconditions not met',
      );
    }
    if ((definition.riskLevel == RiskLevel.r3 ||
            definition.riskLevel == RiskLevel.r4) &&
        !riskOk) {
      return SkillExecutionResult(
        skillId: id,
        status: SkillExecutionStatus.denied,
        reason: 'high-risk skill requires risk-ok',
      );
    }
    try {
      final output = runner();
      return SkillExecutionResult(
        skillId: id,
        status: SkillExecutionStatus.ok,
        reason: 'ok',
        output: output,
      );
    } catch (e) {
      return SkillExecutionResult(
        skillId: id,
        status: SkillExecutionStatus.failed,
        reason: 'runner failed: $e',
      );
    }
  }
}

/// The skills that actually exist in this repo, with honest maturity.
/// Station and full hospital payment skills are NOT registered here,
/// because they do not exist -- registering them would be the exact
/// "UI-only claimed as implemented" failure the spec forbids. In v0.4
/// the old traffic-crossing-decision skill is DELETED and replaced by
/// traffic_scene_info, which only informs and never grants permission
/// to cross (see modules/traffic_scene.dart).
SkillRegistry defaultSkillRegistry() {
  final registry = SkillRegistry();
  registry.register(const SkillDefinition(
    id: 'route_planning',
    name: '路线规划',
    version: '1.0',
    scene: 'campus-library',
    inputs: ['from', 'to'],
    outputs: ['best_route', 'all_routes'],
    preconditions: ['map_provider_available'],
    requiredModules: ['map_navigation', 'route_scoring'],
    riskLevel: RiskLevel.r1,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'outdoor_navigation',
    name: '户外导航',
    version: '1.0',
    scene: 'campus-library',
    inputs: ['route', 'navigation_state'],
    outputs: ['speech_prompt'],
    preconditions: ['navigating_state', 'straight_segment_confirmed'],
    requiredModules: ['speech_scheduler', 'task_manager'],
    riskLevel: RiskLevel.r2,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'environment_analysis',
    name: '环境分析',
    version: '1.0',
    scene: 'all',
    inputs: ['risk_event'],
    outputs: ['risk_assessment'],
    requiredModules: ['risk_engine'],
    riskLevel: RiskLevel.r2,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'tactile_paving_assessment',
    name: '盲道与通道判断',
    version: '1.0',
    scene: 'outdoor',
    inputs: ['blind_path_visible', 'blocked', 'alternative_confirmed'],
    outputs: ['recommendation'],
    requiredModules: ['blind_path'],
    riskLevel: RiskLevel.r2,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'obstacle_assistance',
    name: '障碍处理',
    version: '1.0',
    scene: 'outdoor',
    inputs: ['risk_event'],
    outputs: ['step_or_stop'],
    preconditions: ['spatial_evidence_checked'],
    requiredModules: ['risk_engine', 'speech_scheduler'],
    riskLevel: RiskLevel.r3,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'destination_finding',
    name: '目的地入口定位',
    version: '1.0',
    scene: 'campus-library',
    inputs: ['candidates', 'location_accuracy_m'],
    outputs: ['entrance_result'],
    requiredModules: ['entrance_finding'],
    riskLevel: RiskLevel.r1,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'indoor_navigation',
    name: '室内导航（图书馆）',
    version: '1.0',
    scene: 'library',
    inputs: ['verified_evidence'],
    outputs: ['next_step'],
    requiredModules: ['indoor_task'],
    riskLevel: RiskLevel.r1,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'hospital_registration',
    name: '医院挂号辅助（前置步骤）',
    version: '0.2',
    scene: 'hospital',
    inputs: ['verified_evidence'],
    outputs: ['next_step'],
    requiredModules: ['hospital_task'],
    riskLevel: RiskLevel.r2,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'emergency_assistance',
    name: '紧急求助',
    version: '1.0',
    scene: 'all',
    inputs: ['trigger'],
    outputs: ['local_emergency_result'],
    requiredModules: ['emergency'],
    riskLevel: RiskLevel.r4,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'recording_management',
    name: '录像管理',
    version: '1.0',
    scene: 'all',
    inputs: ['consent'],
    outputs: ['recording_status'],
    permissions: ['user_consent'],
    requiredModules: ['recording'],
    riskLevel: RiskLevel.r1,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'traffic_scene_info',
    name: '路口信息提示（只提示，不放行）',
    version: '1.0',
    scene: 'outdoor',
    inputs: ['light_detected', 'light_direction_confirmed', 'location_accuracy_ok'],
    outputs: ['caution_or_info_text'],
    requiredModules: ['traffic_scene', 'risk_engine'],
    riskLevel: RiskLevel.r2,
    maturity: SkillMaturity.tested,
  ));
  registry.register(const SkillDefinition(
    id: 'system_diagnostics',
    name: '系统诊断',
    version: '0.1',
    scene: 'all',
    inputs: ['service_name'],
    outputs: ['service_health'],
    requiredModules: ['health_monitor'],
    riskLevel: RiskLevel.r0,
    maturity: SkillMaturity.implemented,
  ));
  registry.register(const SkillDefinition(
    id: 'user_feedback_collection',
    name: '用户反馈收集',
    version: '0.1',
    scene: 'all',
    inputs: ['feedback'],
    outputs: ['recorded'],
    requiredModules: ['event_bus'],
    riskLevel: RiskLevel.r0,
    maturity: SkillMaturity.notStarted,
    enabledByDefault: false,
  ));
  return registry;
}
