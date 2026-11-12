/// Phone voice recorder (record package).
///
/// One press = one clip: [start] opens a fresh temporary WAV
/// file at 16 kHz mono -- AudioEncoder.wav IS the 16-bit PCM
/// encoder (the platform interface names it just `wav`; the
/// brief's `wav16` denotes the same encoder) -- (the format the cloud ASR route
/// accepts), [stop] reads the bytes back and deletes the file,
/// [cancel] deletes it unread. Recording never streams and
/// never continues in the background: the only entry points
/// are the press-and-hold gestures in main.dart, and the
/// caller caps the length at 10 s.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'voice_recorder.dart';

VoiceRecorder createVoiceRecorder() => RecordPackageVoiceRecorder();

class RecordPackageVoiceRecorder
    implements VoiceRecorder, VoiceRecorderAmplitude {
  // Created lazily on first use: the record plugin's
  // constructor immediately opens its platform channel, and
  // constructing it eagerly (e.g. in initState) would hit
  // the channel on platforms/tests where recording is
  // never used.
  AudioRecorder? _recorderOrNull;
  AudioRecorder get _recorder => _recorderOrNull ??= AudioRecorder();
  String? _path;
  bool _recording = false;

  @override
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      // No recorder plugin on this platform (web, test
      // hosts): honestly unavailable, never a crash.
      return false;
    }
  }

  @override
  Future<void> start() async {
    final Directory dir = await getTemporaryDirectory();
    final String path =
        '${dir.path}/mingtu_asr_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _path = path;
    _recording = true;
  }

  @override
  Future<Uint8List?> stop() async {
    _recording = false;
    final String? path = await _recorder.stop();
    final String target = path ?? _path ?? '';
    _path = null;
    if (target.isEmpty) return null;
    final File file = File(target);
    try {
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Cleanup failure must not fail the recognition turn.
      }
    }
  }

  @override
  Future<void> cancel() async {
    _recording = false;
    try {
      await _recorder.cancel();
    } catch (_) {
      // Nothing recorded is a valid outcome for a cancel.
    }
    final String? path = _path;
    _path = null;
    if (path != null) {
      try {
        final File file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  @override
  bool get isRecording => _recording;

  /// Live amplitude in dBFS while recording (the record
  /// package polls the platform amplitude at the given
  /// interval; its `Amplitude.current` is documented as
  /// dBFS). Used only by the TalkBack toggle mode's
  /// silence auto-end; an error on this stream simply ends
  /// the feed, never the recording.
  @override
  Stream<double> amplitudeDbfs() {
    return _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 200))
        .map((Amplitude amplitude) => amplitude.current);
  }
}
