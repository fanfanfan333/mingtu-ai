import 'package:test/test.dart';
import 'package:mingtu_ai/core/llm_gateway.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/voice_startup.dart';

/// P0 follow-up regression tests (blind-first / Chinese voice).
///
/// The defects pinned here:
/// 1. Startup greeting only ran when ASR initialised, so an ASR
///    failure with working TTS left a blind user in total silence.
/// 2. zh-CN was "set" on the TTS engine but never verified, so a
///    device without Chinese voice data was reported as Chinese
///    speech working.
/// 3. A voice stop only paused the straight prompt; navigation
///    prompts still queued behind it could be spoken afterwards.
/// 4. The LLM gateway defaulted to a vision model id (VL) although
///    the verified current model is the text model qwen-flash.
void main() {
  group('resolveChineseTtsLocale', () {
    test('accepts zh-CN as the engine spells it', () {
      expect(resolveChineseTtsLocale(const ['en-US', 'zh-CN']), 'zh-CN');
      expect(resolveChineseTtsLocale(const ['zh_CN']), 'zh_CN');
      expect(resolveChineseTtsLocale(const ['ZH-cn']), 'ZH-cn');
      expect(resolveChineseTtsLocale(const ['zh-Hans-CN']), 'zh-Hans-CN');
    });

    test('rejects non-mainland variants and empty lists', () {
      // zh-TW is Chinese, but it is not the zh-CN voice this app
      // promises; unknown must not be treated as verified.
      expect(resolveChineseTtsLocale(const ['zh-TW', 'en-US']), isNull);
      expect(resolveChineseTtsLocale(const ['en-US']), isNull);
      expect(resolveChineseTtsLocale(const <String>[]), isNull);
    });
  });

  group('planStartupVoice', () {
    test('TTS and ASR healthy: greeting spoken, auto-listen on', () {
      final plan = planStartupVoice(
        ttsEngineOk: true,
        chineseVoiceVerified: true,
        asrOk: true,
      );
      expect(plan.channel, StartupVoiceChannel.speech);
      expect(plan.spokenText, contains('明途已启动'));
      expect(plan.spokenText, contains('语音识别已开启'));
      expect(plan.startAutoListen, isTrue);
    });

    test('ASR failed but TTS healthy: greeting still spoken, '
        'with the failure and a next step, never silence', () {
      final plan = planStartupVoice(
        ttsEngineOk: true,
        chineseVoiceVerified: true,
        asrOk: false,
      );
      expect(plan.channel, StartupVoiceChannel.speech);
      expect(plan.spokenText, isNotNull);
      expect(plan.spokenText, contains('明途已启动'));
      expect(plan.spokenText, contains('语音识别暂时不可用'));
      expect(plan.spokenText, contains('麦克风权限'));
      // Must never claim recognition is on when it is not.
      expect(plan.spokenText, isNot(contains('语音识别已开启')));
      expect(plan.startAutoListen, isFalse);
      expect(plan.summary, contains('语音识别不可用'));
    });

    test('engine answers but no zh-CN voice: not speech, no fake '
        'voice announcement of the failure', () {
      final plan = planStartupVoice(
        ttsEngineOk: true,
        chineseVoiceVerified: false,
        asrOk: true,
      );
      expect(plan.channel, StartupVoiceChannel.hapticAndStatus);
      expect(plan.spokenText, isNull);
      expect(plan.startAutoListen, isFalse);
      expect(plan.summary, contains('缺少 zh-CN'));
      expect(plan.summary, contains('不可依赖'));
    });

    test('TTS engine down: haptic/status channel, nothing spoken', () {
      final plan = planStartupVoice(
        ttsEngineOk: false,
        chineseVoiceVerified: false,
        asrOk: false,
      );
      expect(plan.channel, StartupVoiceChannel.hapticAndStatus);
      expect(plan.spokenText, isNull);
      expect(plan.summary, contains('语音播报不可用'));
    });
  });

  group('voiceNoticeText safety contract', () {
    const forbidden = <String>[
      '向左',
      '向右',
      '左转',
      '右转',
      '安全前进',
      '可以前进',
      '放心走',
      '安全通过',
    ];
    test('no notice gives a step direction or a safety promise', () {
      for (final kind in VoiceNoticeKind.values) {
        final text = voiceNoticeText(kind);
        for (final bad in forbidden) {
          expect(text.contains(bad), isFalse,
              reason: '$kind must not contain "$bad": $text');
        }
      }
    });

    test('unavailable states are announced as unknown, with help', () {
      expect(voiceNoticeText(VoiceNoticeKind.navigationUnavailable),
          contains('无法确认路线'));
      expect(voiceNoticeText(VoiceNoticeKind.detectionUnavailable),
          contains('无法确认前方情况'));
      expect(voiceNoticeText(VoiceNoticeKind.locationUnavailable),
          contains('不知道你现在的位置'));
      expect(voiceNoticeText(VoiceNoticeKind.serviceError),
          contains('暂时不可用'));
      expect(voiceNoticeText(VoiceNoticeKind.asrUnavailable),
          contains('可能听不见'));
    });

    test('navigation ended does not claim arrival', () {
      final text = voiceNoticeText(VoiceNoticeKind.navigationEnded);
      expect(text, contains('导航已结束'));
      expect(text, contains('不代表已经到达'));
    });

    test('tts-down text admits it was not read aloud', () {
      expect(voiceNoticeText(VoiceNoticeKind.ttsUnavailable),
          contains('未被读出'));
    });
  });

  group('SpeechScheduler stop semantics', () {
    SpeechRequest req(String id, SpeechKind kind, DateTime now) =>
        SpeechRequest(
          id: id,
          eventId: 'e-$id',
          text: '提示$id',
          kind: kind,
          createdAt: now,
          expiresAt: now.add(const Duration(seconds: 60)),
          navigationStateVersion: 'v1',
        );

    test('danger interrupts a low-priority navigation prompt', () {
      final s = SpeechScheduler();
      final now = DateTime(2026, 11, 9, 10, 0, 0);
      expect(s.submit(req('nav-info', SpeechKind.info, now), now), isTrue);
      expect(s.active?.id, 'nav-info');
      expect(
          s.submit(req('danger', SpeechKind.obstacleAvoidance, now), now),
          isTrue);
      expect(s.active?.id, 'danger');
      expect(s.interruptedLog, contains('nav-info'));
    });

    test('emergency interrupts a turn prompt', () {
      final s = SpeechScheduler();
      final now = DateTime(2026, 11, 9, 10, 0, 0);
      expect(s.submit(req('turn1', SpeechKind.turn, now), now), isTrue);
      expect(s.submit(req('emg', SpeechKind.emergency, now), now), isTrue);
      expect(s.active?.id, 'emg');
    });

    test('cancelAll clears active and queued navigation speech; '
        'nothing is promoted afterwards', () {
      final s = SpeechScheduler();
      final now = DateTime(2026, 11, 9, 10, 0, 0);
      expect(s.submit(req('danger', SpeechKind.obstacleAvoidance, now), now),
          isTrue);
      // A turn submitted now would be *dropped* by the conflict rule
      // (it conflicts with the active avoidance warning), so queue
      // two non-conflicting prompts instead.
      expect(s.submit(req('info1', SpeechKind.info, now), now), isTrue);
      expect(s.submit(req('danger2', SpeechKind.obstacleAvoidance, now), now),
          isTrue);
      expect(s.queue.length, 2);
      final cancelled = s.cancelAll();
      expect(cancelled, containsAll(<String>['danger', 'danger2', 'info1']));
      expect(s.active, isNull);
      expect(s.queue, isEmpty);
      expect(
        s.promoteNext(now,
            straightSegmentConfirmed: true, riskActive: false),
        isNull,
      );
      expect(s.cancelledLog, containsAll(cancelled));
    });

    test('a fresh confirmation can still be submitted after cancelAll',
        () {
      final s = SpeechScheduler();
      final now = DateTime(2026, 11, 9, 10, 0, 0);
      s.submit(req('turn1', SpeechKind.turn, now), now);
      s.cancelAll();
      expect(s.submit(req('confirm-stop', SpeechKind.info, now), now),
          isTrue);
      expect(s.active?.id, 'confirm-stop');
    });
  });

  group('model configuration', () {
    test('gateway default is the verified text model qwen-flash, '
        'not a vision model', () {
      final g = LlmGateway(budgetCapRmb: 100);
      expect(g.modelId, 'qwen-flash');
      expect(g.modelId.toLowerCase().contains('vl'), isFalse);
    });
  });
}
