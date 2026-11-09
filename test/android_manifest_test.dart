import 'dart:io';

import 'package:test/test.dart';

/// Regression test for the Android submission build failure:
///
/// `flutter build apk --debug` failed in `processDebugMainManifest` with
/// "not well-formed (invalid token): line 5, column 48" because the comment
/// at the top of `android/app/src/main/AndroidManifest.xml` contained the
/// sequence `--` twice ("no GPS code yet -- the Amap ..." and
/// "--dart-define"). The XML specification forbids `--` inside a comment
/// body, so the manifest was not legal XML at all.
///
/// Dart core ships no XML parser, so this test pins the exact invariant
/// that broke the build: no XML comment in any shipped AndroidManifest.xml
/// may contain `--` in its body, comment delimiters must be balanced, and
/// (for the main manifest) the referenced launcher icon resource must
/// exist so AAPT resource linking cannot fail on a missing mipmap.
void main() {
  const manifestPaths = <String>[
    'android/app/src/main/AndroidManifest.xml',
    'android/app/src/debug/AndroidManifest.xml',
    'android/app/src/profile/AndroidManifest.xml',
  ];

  for (final path in manifestPaths) {
    group(path, () {
      late String content;

      setUpAll(() {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$path must exist (run tests from the project root)');
        content = file.readAsStringSync();
      });

      test('has balanced comment delimiters and no "--" inside comments', () {
        var cursor = 0;
        var comments = 0;
        while (true) {
          final open = content.indexOf('<!--', cursor);
          if (open == -1) break;
          final close = content.indexOf('-->', open + 4);
          expect(close, isNot(-1),
              reason: 'unterminated XML comment starting at offset $open');
          final body = content.substring(open + 4, close);
          expect(body.contains('--'), isFalse,
              reason: 'XML comments must not contain "--" (invalid token in '
                  'the Android manifest merger). Comment body: $body');
          comments++;
          cursor = close + 3;
        }
        expect(comments, greaterThan(0),
            reason: 'expected at least one comment to actually be checked');
      });

      test('has no stray "--" outside comments either', () {
        // Strip every well-formed comment, then any remaining "--" would
        // be inside markup or text, which is likewise not legal here.
        final stripped =
            content.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
        expect(stripped.contains('--'), isFalse,
            reason: 'unexpected "--" outside an XML comment');
      });
    });
  }

  test('main manifest launcher icon resource exists', () {
    final mainManifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final iconMatch = RegExp(r'android:icon="@mipmap/([A-Za-z0-9_]+)"')
        .firstMatch(mainManifest);
    expect(iconMatch, isNotNull,
        reason: 'main manifest must declare a mipmap launcher icon');
    final iconName = iconMatch!.group(1)!;
    const resDir = 'android/app/src/main/res';
    final candidates = <String>[
      // Density-specific raster icons (any one bucket satisfies AAPT).
      for (final density in const [
        'mdpi',
        'hdpi',
        'xhdpi',
        'xxhdpi',
        'xxxhdpi',
      ])
        '$resDir/mipmap-$density/$iconName.png',
      // Adaptive icon (API 26+) defined entirely in XML.
      '$resDir/mipmap-anydpi-v26/$iconName.xml',
    ];
    final found = candidates.where((p) => File(p).existsSync()).toList();
    expect(found, isNotEmpty,
        reason: '@mipmap/$iconName is referenced by the manifest but no icon '
            'resource exists; AAPT linking fails without one. Looked for: '
            '${candidates.join(', ')}');

    // P0 follow-up: API 24-25 (minSdk 24) predates adaptive icons,
    // so a legacy fallback must ALSO exist: a density-bucket icon
    // (PNG or vector XML) that pre-26 devices can resolve. An
    // anydpi-v26-only icon leaves API 24/25 with no launcher icon.
    final legacy = <String>[
      for (final density in const [
        'mdpi',
        'hdpi',
        'xhdpi',
        'xxhdpi',
        'xxxhdpi',
      ]) ...<String>[
        '$resDir/mipmap-$density/$iconName.png',
        '$resDir/mipmap-$density/$iconName.xml',
      ],
    ];
    expect(legacy.where((p) => File(p).existsSync()), isNotEmpty,
        reason: 'no pre-26 launcher icon fallback (density bucket) exists; '
            'looked for: ${legacy.join(', ')}');
    expect(File('$resDir/mipmap-anydpi-v26/$iconName.xml').existsSync(), isTrue,
        reason: 'adaptive icon (API 26+) must also be present');
  });

  group('APK size: legacy packaging + arm64-only native libs', () {
    test('gradle compresses .so and excludes non-arm64 ABIs', () {
      final String gradle =
          File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('useLegacyPackaging = true'));
      expect(gradle, contains('"lib/x86_64/**"'));
      expect(gradle, contains('"lib/x86/**"'));
      expect(gradle, contains('"lib/armeabi-v7a/**"'));
      // ABI choice stays in the build command (README), never
      // in a hardcoded filter that would fight --split-per-abi.
      expect(gradle, isNot(contains('abiFilters =')));
      expect(gradle, isNot(contains('abiFilters +=')));
    });
  });

  group('release launch identity and ABI (P0, 2026-11-09)', () {
    test('the app label is 明途', () {
      final String mainManifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(mainManifest, contains('android:label="明途"'));
    });

    test(
        'ABI is chosen by the build command, not a hardcoded '
        'abiFilters (which conflicts with --split-per-abi)', () {
      final String gradle =
          File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, isNot(contains('abiFilters +=')));
      expect(gradle, isNot(contains('abiFilters =')));
      final String readme = File('README.md').readAsStringSync();
      expect(readme, contains('--target-platform android-arm64'));
      expect(readme, contains('--split-per-abi'));
    });

    test(
        'legacy packaging IS used now, together with the '
        'non-arm64 excludes (the earlier larger measurement '
        'was a multi-ABI build without excludes)', () {
      final String gradle =
          File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('useLegacyPackaging = true'));
      expect(gradle, contains('"lib/x86_64/**"'));
    });

    test(
        'R8 cannot strip the Room/WorkManager classes again '
        '(proguard rules exist, are wired in, demo minify off)', () {
      final File rules = File('android/app/proguard-rules.pro');
      expect(rules.existsSync(), isTrue);
      final String pro = rules.readAsStringSync();
      expect(pro, contains('-keep class * extends androidx.room.RoomDatabase'));
      expect(pro, contains('-keep class androidx.room.**'));
      expect(pro, contains('-keep class androidx.work.**'));
      final String gradle =
          File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('"proguard-rules.pro"'));
      expect(gradle, contains('isMinifyEnabled = false'));
      expect(gradle, contains('isShrinkResources = false'));
    });
  });
}
