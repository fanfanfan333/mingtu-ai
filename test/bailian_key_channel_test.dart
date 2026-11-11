import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the user decision (2026-11-09): the APK must contain
/// NO Bailian key injection point. The Bailian key exists only
/// in the server function's environment (Alibaba Cloud FC).
/// This source-level test fails if the client dart-define key
/// channel -- or any client code that reads a Bailian key --
/// ever comes back.
void main() {
  test('no Bailian key channel anywhere under lib/', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue);
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String text = entity.readAsStringSync();
      for (final String needle in <String>[
        'MINGTU_DASHSCOPE_API_KEY',
        'dashscopeApiKey',
        'hasDashscopeKey',
        'BailianClient',
      ]) {
        if (text.contains(needle)) {
          offenders.add('${entity.path}: $needle');
        }
      }
      // No Authorization Bearer header may be constructed
      // client-side for DashScope any more.
      if (text.contains("'Authorization': 'Bearer") ||
          text.contains('"Authorization": "Bearer')) {
        offenders.add('${entity.path}: bearer header');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the former client file is an inert tombstone', () {
    // The snapshot push channel cannot delete files, so the
    // former client file remains as documentation-only: it
    // must declare no client and read no key.
    final File f = File('lib/adapters/bailian_client.dart');
    expect(f.existsSync(), isTrue);
    final String text = f.readAsStringSync();
    expect(text.contains('class '), isFalse);
    expect(text.contains('fromEnvironment'), isFalse);
  });
}
