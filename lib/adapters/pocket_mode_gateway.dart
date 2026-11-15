import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

import '../core/pocket_mode.dart';

Stream<bool> proximityEvents() =>
    ProximitySensor.events.map((event) => event > 0);

class FilePocketModeStore implements PocketModeStore {
  FilePocketModeStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/mingtu_pocket_mode.txt');

  @override
  Future<bool> load() async {
    try {
      return (await (await _file()).readAsString()).trim() == 'true';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> save(bool enabled) async {
    try {
      await (await _file()).writeAsString('$enabled');
    } catch (_) {/* Keep the current session usable. */}
  }
}
