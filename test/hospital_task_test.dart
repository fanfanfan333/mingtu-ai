import 'package:mingtu_ai/modules/hospital_task.dart';
import 'package:test/test.dart';

void main() {
  test('steps advance only with verification', () {
    final task = HospitalTask();
    expect(task.tryAdvance(verified: false), isFalse);
    expect(task.currentStep, HospitalStep.locateRegistration);
    expect(task.tryAdvance(verified: true, evidence: 'saw desk'), isTrue);
    expect(task.tryAdvance(verified: true), isTrue);
    expect(task.tryAdvance(verified: true), isTrue);
    expect(task.preRegistrationComplete, isTrue);
    expect(task.tryAdvance(verified: true), isFalse);
  });

  test('pre-registration complete is never a completed registration', () {
    final task = HospitalTask();
    for (var i = 0; i < 3; i++) {
      task.tryAdvance(verified: true);
    }
    expect(task.preRegistrationComplete, isTrue);
    expect(task.isFullyCompleted, isFalse);
    expect(task.currentStepText, contains('不能算挂号成功'));
  });
}
