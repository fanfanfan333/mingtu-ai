/// UI-A11Y S1 (UI-01): silence auto-end for the cloud
/// recording path, as a PURE tracker fed with amplitude
/// samples.
///
/// The local-ASR path already ends on silence through the
/// recogniser's own pauseFor (3 s). The recorder path has
/// no such signal, so the TalkBack toggle mode watches the
/// recorder's amplitude stream instead (the `record`
/// package's `onAmplitudeChanged`, whose values are dBFS --
/// see adapters/voice_recorder.dart): once speech has
/// actually been heard, [silenceDuration] of continuous
/// quiet ends the clip early, mirroring the pauseFor
/// semantics. A clip in which NO speech was ever heard
/// never triggers: it ends by release, by the toggle, or
/// by the existing 10 s hard cap, exactly as before.
library;

/// Fed one amplitude sample at a time; [addSample] returns
/// true exactly once, at the moment the silence end is
/// due. Time comes from the caller, so fixtures drive the
/// tracker with scripted (level, instant) sequences.
class RecordingSilenceTracker {
  RecordingSilenceTracker();

  /// A sample at or above this level counts as speech.
  /// Basis: normal speech peaks at a phone microphone sit
  /// well above -30 dBFS; -40 leaves margin for a quiet
  /// speaker or a held-away phone.
  static const double voiceThresholdDbfs = -40.0;

  /// A sample below this level counts as quiet. Basis: a
  /// quiet room's noise floor at a phone microphone sits
  /// around -50 to -60 dBFS. The band between the two
  /// thresholds is hysteresis: an in-band sample is treated
  /// as neither speech nor quiet and restarts the quiet
  /// run, so borderline rustling cannot accumulate towards
  /// an end the user did not intend.
  static const double silenceThresholdDbfs = -50.0;

  /// Continuous quiet required before the end fires --
  /// the same 3 s the recogniser's pauseFor uses.
  static const Duration silenceDuration = Duration(seconds: 3);

  bool _heardVoice = false;
  DateTime? _quietSince;
  bool _fired = false;

  /// Whether any sample has crossed the voice threshold
  /// in this clip.
  bool get heardVoice => _heardVoice;

  /// Feed one sample ([dbfs] in dBFS, taken at [at]).
  /// Returns true when the silence end is due (once).
  bool addSample(double dbfs, DateTime at) {
    if (_fired) return false;
    if (dbfs >= voiceThresholdDbfs) {
      _heardVoice = true;
      _quietSince = null;
      return false;
    }
    if (!_heardVoice) {
      // Quiet before any speech: the clip simply has not
      // started; never an auto-end.
      return false;
    }
    if (dbfs >= silenceThresholdDbfs) {
      // Hysteresis band: not quiet enough to accumulate.
      _quietSince = null;
      return false;
    }
    final DateTime since = _quietSince ??= at;
    if (at.difference(since) >= silenceDuration) {
      _fired = true;
      return true;
    }
    return false;
  }
}
