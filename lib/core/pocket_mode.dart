import 'dart:async';

import 'package:flutter/foundation.dart';

const pocketNearDuration = Duration(milliseconds: 1500);
const pocketEnabledSpeech = '口袋模式已打开。贴近耳朵或放进口袋后，屏幕触摸会被忽略，检测和语音继续工作。';
const pocketDisabledSpeech = '口袋模式已关闭。';

abstract interface class PocketModeStore {
  Future<bool> load();
  Future<void> save(bool enabled);
}

class PocketMode extends ChangeNotifier {
  PocketMode(
      {required Stream<bool> Function() proximity, DateTime Function()? now})
      : _proximity = proximity,
        _now = now ?? DateTime.now;

  final Stream<bool> Function() _proximity;
  final DateTime Function() _now;
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  DateTime? _nearSince;
  bool _enabled = false;
  bool _foreground = true;
  bool _locked = false;
  bool get enabled => _enabled;
  bool get ignoreTouches => _enabled && _foreground && _locked;

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _sync();
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    _nearSince = null;
    _locked = false;
    _subscription?.cancel();
    _subscription = null;
    if (_enabled && _foreground) {
      try {
        _subscription = _proximity().listen(_onProximity, onError: (Object _) {
          _timer?.cancel();
          _timer = null;
          _nearSince = null;
          _locked = false;
          notifyListeners();
        });
      } catch (_) {
        // A missing sensor leaves touch available.
      }
    }
    notifyListeners();
  }

  void _onProximity(bool near) {
    if (!near) {
      _timer?.cancel();
      _timer = null;
      _nearSince = null;
      if (_locked) {
        _locked = false;
        notifyListeners();
      }
      return;
    }
    _nearSince ??= _now();
    final remaining = pocketNearDuration - _now().difference(_nearSince!);
    if (remaining <= Duration.zero) {
      _lock();
    } else {
      _timer ??= Timer(remaining, _lock);
    }
  }

  void _lock() {
    _timer = null;
    if (_nearSince == null || !_enabled || !_foreground) return;
    final remaining = pocketNearDuration - _now().difference(_nearSince!);
    if (remaining > Duration.zero) {
      _timer = Timer(remaining, _lock);
      return;
    }
    if (!_locked) {
      _locked = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
