import '../config/app_config.dart';

const String foregroundCameraStallText = '摄像头画面没有更新。请到系统设置里把明途的省电策略改成无限制。';
const String foregroundLocationStallText = '定位没有更新。请到系统设置里把明途的省电策略改成无限制。';

class ForegroundWatchdog {
  ForegroundWatchdog({required this.now, required this.onFault});
  final DateTime Function() now;
  final void Function(String) onFault;
  bool _foreground = false;
  bool _camera = false;
  bool _location = false;
  DateTime? _cameraAt, _locationAt;
  bool _cameraLatched = false, _locationLatched = false;

  bool get cameraFaultActive => _foreground && _camera && _cameraLatched;
  bool get locationFaultActive => _foreground && _location && _locationLatched;

  void update(
      {required bool foreground,
      required bool camera,
      required bool location}) {
    final t = now();
    if (foreground && (!_foreground || (camera && !_camera))) {
      _cameraAt = t;
      _cameraLatched = false;
    }
    if (foreground && (!_foreground || (location && !_location))) {
      _locationAt = t;
      _locationLatched = false;
    }
    _foreground = foreground;
    _camera = camera;
    _location = location;
    if (!foreground) return;
    if (camera &&
        !_cameraLatched &&
        _cameraAt != null &&
        t.difference(_cameraAt!) >= AppConfig.foregroundCameraStallThreshold) {
      _cameraLatched = true;
      onFault(foregroundCameraStallText);
    }
    if (location &&
        !_locationLatched &&
        _locationAt != null &&
        t.difference(_locationAt!) >=
            AppConfig.foregroundLocationStallThreshold) {
      _locationLatched = true;
      onFault(foregroundLocationStallText);
    }
  }

  void cameraCallback() {
    _cameraAt = now();
    _cameraLatched = false;
  }

  void locationCallback() {
    _locationAt = now();
    _locationLatched = false;
  }
}
