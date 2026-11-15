import 'dart:async';
import 'package:flutter/services.dart';

abstract class PttFeedback {
  Future<void> start();
  Future<void> end();
}

class SystemPttFeedback implements PttFeedback {
  @override
  Future<void> start() async {
    try {
      await HapticFeedback.vibrate();
    } catch (_) {}
  }

  @override
  Future<void> end() async {
    try {
      await HapticFeedback.vibrate();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await HapticFeedback.vibrate();
    } catch (_) {}
  }
}

/// Test seam; no beep is played by the default implementation.
PttFeedback? mingtuPttFeedbackOverride;
