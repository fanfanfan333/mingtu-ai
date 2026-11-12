/// Phone guide store: the first-launch marker is one
/// small file in the app support directory (path_provider,
/// already a dependency of this app). Any failure to reach
/// storage answers "seen" -- see the [GuideStore]
/// contract for why guessing "first launch" would be the
/// dishonest direction.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/permission_flow.dart';

GuideStore createGuideStore() => FileGuideStore();

class FileGuideStore implements GuideStore {
  static const String _fileName = 'mingtu_guide_seen.txt';

  Future<File?> _markerFile() async {
    try {
      final Directory dir = await getApplicationSupportDirectory();
      return File('${dir.path}/$_fileName');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasSeenGuide() async {
    final File? file = await _markerFile();
    if (file == null) return true;
    try {
      return await file.exists();
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> markGuideSeen() async {
    final File? file = await _markerFile();
    if (file == null) return;
    try {
      await file.writeAsString('seen');
    } catch (_) {
      // A failed write only means the guide may run once
      // more on a later launch; it must never fail startup.
    }
  }
}
