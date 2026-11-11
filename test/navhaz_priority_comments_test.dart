/// NAVHAZ M1 fix round, item 3: comment wording guard.
///
/// Speech priorities are the SIX enum levels of
/// speech_scheduler.dart -- emergency = 0, danger = 1,
/// obstacleAvoidance / alert = 2, turn = 3, straight = 4,
/// info = 5. Older comments (written against a five-level
/// draft, or against the workstream labels of earlier
/// milestones) called danger "P0", which misstates the
/// enum: danger is level 1; level 0 is emergency alone.
///
/// This guard extracts the COMMENT text of every Dart
/// file under lib/ (string literals are skipped by the
/// scanner, so code identifiers such as `_p0SpeechPlaying`
/// and spoken texts are out of scope by construction) and
/// asserts no P0-P5 token survives in any comment -- a
/// superset of the specific failure Codex flagged (a
/// comment juxtaposing "P0" with danger), which the second
/// assertion states explicitly for the record.
library;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Extract comment text (// line and /* */ block) from
/// Dart source, skipping string literals (single, double,
/// triple-quoted; interpolation nesting beyond one level
/// is not needed for this guard).
String extractComments(String src) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  bool inLine = false;
  bool inBlock = false;
  String? quote;
  bool triple = false;
  while (i < src.length) {
    final String c = src[i];
    final String next = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write('\n');
      } else {
        out.write(c);
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
      } else {
        out.write(c);
        i++;
      }
      continue;
    }
    if (quote != null) {
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (triple) {
        if (c == quote && next == quote && i + 2 < src.length && src[i + 2] == quote) {
          i += 3;
          quote = null;
          triple = false;
          continue;
        }
      } else if (c == quote) {
        quote = null;
      }
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      if (next == c && i + 2 < src.length && src[i + 2] == c) {
        triple = true;
        i += 3;
      } else {
        i++;
      }
      quote = c;
      continue;
    }
    i++;
  }
  return out.toString();
}

void main() {
  test('no lib comment uses a P0-P5 token for speech priority', () {
    final List<File> files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final RegExp token = RegExp(r'\bP[0-5]\b');
    // The specific juxtaposition Codex flagged, stated
    // explicitly: "P0" within a short span of "danger" in
    // either order.
    final RegExp juxtaposition = RegExp(
        r'P0[^.\n]{0,12}danger|danger[^.\n]{0,12}P0',
        caseSensitive: false);
    for (final File f in files) {
      final String comments = extractComments(f.readAsStringSync());
      expect(token.hasMatch(comments), isFalse,
          reason: '${f.path} comment still carries a P-level '
              'token; use the six-level wording (emergency = '
              'level 0, danger = level 1, obstacleAvoidance / '
              'alert = level 2, turn = level 3, straight = '
              'level 4, info = level 5)');
      expect(juxtaposition.hasMatch(comments), isFalse,
          reason: '${f.path} juxtaposes P0 with danger');
    }
  });

  test('the six-level table itself is the scheduler header', () {
    final String src =
        File('lib/core/speech_scheduler.dart').readAsStringSync();
    final String comments = extractComments(src);
    expect(comments.contains('0 emergency'), isTrue);
    expect(comments.contains('1 danger'), isTrue);
    expect(comments.contains('5 info'), isTrue);
  });
}
