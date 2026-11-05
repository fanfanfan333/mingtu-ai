/// Skill: hospital_registration (v0.1, NOT_IMPLEMENTED - interface only).
///
/// This file exists so the task-planning interface is visible, but the
/// full hospital registration flow (find registration area, read machine
/// instructions, assist payment/identity steps, verify completion) is
/// NOT implemented in v0.1 and must NOT be claimed, demoed or submitted
/// as a working feature. Any call to [execute] reports that status
/// instead of pretending to complete a registration.
enum SkillStatus { notImplemented, implemented, tested, fieldValidated }

class HospitalRegistrationResult {
  final SkillStatus status;
  final String message;
  const HospitalRegistrationResult(this.status, this.message);
}

class HospitalRegistrationSkill {
  static const SkillStatus status = SkillStatus.notImplemented;

  HospitalRegistrationResult execute() {
    return const HospitalRegistrationResult(
      SkillStatus.notImplemented,
      '医院挂号完整流程未实现：本版本仅为接口占位，不能用于真实挂号引导。',
    );
  }
}
