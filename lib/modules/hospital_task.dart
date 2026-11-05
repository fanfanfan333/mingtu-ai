/// Hospital pre-registration guidance logic for Mingtu AI.
///
/// This replaces the old NOT_IMPLEMENTED stub for the *guidance* steps
/// only: find the registration area, read the machine instructions,
/// confirm the pre-registration position. Every step still requires
/// verification evidence to advance, exactly like the library indoor
/// task, and speech completion never counts as action completion.
///
/// Hard boundary, enforced by construction: [isFullyCompleted] is
/// always false. Payment and identity verification are NOT implemented
/// and are not part of this task, so this module can NEVER report a
/// registration as successfully completed. A caller that ignores that
/// and presents pre-registration as a completed registration is lying
/// about a medical task, and must not do so.
library;

enum HospitalStep { locateRegistration, readMachine, confirmPosition }

class HospitalTask {
  final List<HospitalStep> steps = const [
    HospitalStep.locateRegistration,
    HospitalStep.readMachine,
    HospitalStep.confirmPosition,
  ];
  int _index = 0;
  bool _preDone = false;
  final List<HospitalStep> verifiedSteps = [];

  HospitalStep? get currentStep => _preDone ? null : steps[_index];
  bool get preRegistrationComplete => _preDone;

  /// Always false: payment / identity steps are not implemented.
  bool get isFullyCompleted => false;

  String get currentStepText {
    switch (currentStep) {
      case HospitalStep.locateRegistration:
        return '请先找到挂号处位置。';
      case HospitalStep.readMachine:
        return '请读出挂号机上的说明文字，确认无误后再继续。';
      case HospitalStep.confirmPosition:
        return '请确认你已在挂号排队位置，不要先缴费。';
      case null:
        return '挂号前置步骤已走完，但缴费和身份核验未实现，'
            '不能算挂号成功，请勿用于真实挂号。';
    }
  }

  bool tryAdvance({required bool verified, String? evidence}) {
    if (_preDone || !verified) return false;
    verifiedSteps.add(steps[_index]);
    _index += 1;
    if (_index >= steps.length) _preDone = true;
    return true;
  }

  void reset() {
    _index = 0;
    _preDone = false;
    verifiedSteps.clear();
  }
}
