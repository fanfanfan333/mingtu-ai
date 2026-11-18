/// Navigation-guidance diagnostics: the evidence trail a
/// real-device report needs.
///
/// Why this exists: the field report ("I only ever hear the
/// obstacle warning, never the first instruction") cannot be
/// reproduced from the source alone -- the interruption, the
/// expiry and the resume all happen inside the speech
/// pipeline, seconds apart, on the phone. This module keeps a
/// small, ordered, greppable record of exactly those moments
/// so a real-device log shows WHAT happened and WHEN.
///
/// Two sinks, one write:
///  * the in-memory ring (read by tests and by the status
///    surface), capped at [GuidanceDiag.maxEntries] lines;
///  * the `MingtuVoice:` log line (tag `NAVDIAG`), so
///    `logcat | grep MingtuVoice` shows the same sequence on
///    a phone.
///
/// Redaction is a HARD requirement, not a courtesy: a
/// diagnostic line is copied into bug reports and chat
/// messages, so it must never carry a position, a URL, a
/// credential, an exception's raw text, or whatever place
/// name the user said. [redact] therefore strips
///  * URLs and anything that looks like a credential
///    (`key=`, `token:` ...),
///  * long hexadecimal runs (hashes / keys),
///  * any decimal number wide enough to be a coordinate
///    component,
///  * every CJK run (place names, spoken text, exception
///    messages in Chinese),
///  * whitespace runs and anything past the length cap.
/// Callers that need a length (a destination's name, for
/// instance) log the NUMBER (`destination_len=6`), never the
/// text.
library;

import '../voice_log.dart';

/// One recorded diagnostic line: an event name, an optional
/// redacted detail, and when it happened.
class GuidanceDiagEntry {
  const GuidanceDiagEntry({
    required this.at,
    required this.event,
    this.detail,
  });

  final DateTime at;
  final String event;
  final String? detail;

  /// `2026-01-01T12:00:00 route_adopted steps=3`
  ///
  /// The timestamp deliberately carries NO sub-second
  /// fraction: with no decimal point in the stamp, a
  /// coordinate-shaped number can only ever come from the
  /// detail, which [GuidanceDiag.redact] has already cleaned.
  String toLine() {
    final String stamp = at.toIso8601String().split('.').first;
    final String? d = detail;
    return d == null || d.isEmpty ? '$stamp $event' : '$stamp $event $d';
  }

  @override
  String toString() => toLine();
}

/// The single, process-wide diagnostic ring. Static (not
/// injected): the guidance decisions that matter are taken in
/// several places -- route adoption, speech arbitration,
/// hazard frames -- and threading a recorder through all of
/// them would make the production wiring depend on test
/// plumbing.
class GuidanceDiag {
  GuidanceDiag._();

  /// Ring capacity. Older lines are dropped first.
  static const int maxEntries = 200;

  /// Longest detail kept, in characters, BEFORE the marker
  /// appended by [redact] (so the stored string is at most
  /// [maxDetailLength] + 3 long).
  static const int maxDetailLength = 120;

  /// The fixed event names this round records. Kept as a set
  /// so a typo in a call site is caught by the test suite
  /// rather than silently producing an unusable log.
  static const Set<String> eventNames = <String>{
    'route_adopted',
    'first_instruction_enqueued',
    'speech_interrupted',
    'speech_expired',
    'tts_started',
    'guidance_resumed',
    'hazard_suppressed',
    'nav_paused_no_fix',
    'arrived_vicinity',
  };

  static final List<GuidanceDiagEntry> _ring = <GuidanceDiagEntry>[];

  /// Clock seam. Production leaves it at [DateTime.now];
  /// tests may install a deterministic one.
  static DateTime Function() clock = DateTime.now;

  // NOTE: Dart's RegExp does not accept inline `(?i)` flags, so
  // case-insensitivity is a constructor argument here.
  static final RegExp _urlPattern =
      RegExp(r'\b(?:https?|ftp)://\S+', caseSensitive: false);
  static final RegExp _credentialPattern = RegExp(
    r'\b(?:key|apikey|api_key|token|secret|password|pwd|sig|signature)\b'
    r'\s*[:=]\s*\S+',
    caseSensitive: false,
  );
  static final RegExp _longHexPattern = RegExp(r'[0-9a-fA-F]{16,}');
  static final RegExp _coordinatePattern = RegExp(r'\d{2,3}\.\d+');
  static final RegExp _cjkPattern = RegExp(r'[\u2E80-\u9FFF\uF900-\uFAFF]+');

  /// Strip everything that must never leave the device.
  ///
  /// Order matters: URLs first (they contain `key=` and
  /// digits), credentials second, then hashes, then
  /// coordinate-shaped numbers, then CJK runs, then
  /// whitespace. Idempotent by construction -- a second pass
  /// finds nothing left to remove.
  static String redact(String? raw) {
    if (raw == null) return '';
    String out = raw;
    out = out.replaceAll(_urlPattern, '<url>');
    out = out.replaceAll(_credentialPattern, '<redacted>');
    out = out.replaceAll(_longHexPattern, '<hex>');
    out = out.replaceAll(_coordinatePattern, '<num>');
    out = out.replaceAll(_cjkPattern, '<text>');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (out.length > maxDetailLength) {
      out = '${out.substring(0, maxDetailLength)}...';
    }
    return out;
  }

  /// Append one line (ring + voice log). The detail is
  /// redacted BEFORE it is stored, so the raw string never
  /// reaches the ring at all.
  static void record(String event, {String? detail}) {
    final String cleaned = redact(detail);
    final GuidanceDiagEntry entry = GuidanceDiagEntry(
      at: clock(),
      event: redact(event),
      detail: cleaned.isEmpty ? null : cleaned,
    );
    _ring.add(entry);
    while (_ring.length > maxEntries) {
      _ring.removeAt(0);
    }
    mingtuVoiceLog('NAVDIAG ${entry.toLine()}');
  }

  /// A copy of the ring, oldest first.
  static List<GuidanceDiagEntry> snapshot() =>
      List<GuidanceDiagEntry>.unmodifiable(_ring);

  /// The ring as newline-separated lines, oldest first.
  static String dumpLines() =>
      _ring.map((GuidanceDiagEntry e) => e.toLine()).join('\n');

  /// How many lines are held right now.
  static int get length => _ring.length;

  /// Drop everything (called when a trip ends, so one trip's
  /// trail is never mistaken for another's).
  static void clear() => _ring.clear();
}
