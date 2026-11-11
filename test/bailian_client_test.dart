import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tombstone (2026-11-09): the direct Bailian client and its
/// tests were removed when the client-side key channel was
/// deleted (Bailian now lives only in the FC server function).
/// The full guard suite is in bailian_key_channel_test.dart;
/// this file keeps one pin here because the snapshot push
/// channel cannot delete files.
void main() {
  test('app config exposes no Bailian key channel', () {
    final String config = File('lib/config/app_config.dart').readAsStringSync();
    expect(config.contains('DASHSCOPE_API_KEY'), isFalse);
    expect(config.contains('dashscopeApiKey'), isFalse);
    expect(config.contains('hasDashscopeKey'), isFalse);
  });
}
