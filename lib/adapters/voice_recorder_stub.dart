/// Web / non-mobile voice recorder: there is no recording
/// pipeline on this platform, so the factory returns the
/// unavailable implementation. Never fakes a clip.
library;

import 'voice_recorder.dart';

VoiceRecorder createVoiceRecorder() => const UnavailableVoiceRecorder();
