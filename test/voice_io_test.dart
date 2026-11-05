import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:test/test.dart';

void main() {
  test('unavailable voice IO reports NOT_CONFIGURED, never fakes speech', () async {
    final output = UnavailableVoiceOutput();
    final input = UnavailableVoiceInput();
    expect(output.isAvailable, isFalse);
    expect(output.status, contains('NOT_CONFIGURED'));
    expect(input.isAvailable, isFalse);
    expect(input.status, contains('NOT_CONFIGURED'));
    await output.speak('hello');
    await expectLater(input.transcripts, emitsDone);
  });
}
