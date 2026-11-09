/// Startup resilience for Mingtu AI.
///
/// Rule: NO startup initialization failure may crash the app --
/// a blind user whose app dies silently on launch has nothing.
/// Every engine initialization (TTS, ASR, YOLO, ...) runs inside
/// [guardStartupStep]: a throw is recorded by module name and
/// the step's fallback is used instead, so startup completes in
/// a degraded state and the user is TOLD, in Chinese, which
/// modules are unavailable (by voice when speech works, on
/// screen + haptics when it does not). [runGuardedMain] adds the
/// last-resort zone + FlutterError backstop around the whole
/// app so even an unexpected framework error is captured into
/// the same log instead of killing the process silently.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Records startup module failures by their Chinese module
/// name, in order, without duplicates.
class StartupFailureLog {
  final List<String> _modules = <String>[];

  List<String> get modules => List<String>.unmodifiable(_modules);
  bool get hasFailures => _modules.isNotEmpty;

  void record(String module) {
    if (!_modules.contains(module)) _modules.add(module);
  }

  void clear() => _modules.clear();
}

/// The shared log the app's startup writes to and the home page
/// reads after initialization, plus the zone-error sink filled
/// by [runGuardedMain] for errors that escaped every step guard.
final StartupFailureLog startupFailures = StartupFailureLog();

/// Run one startup [step]; if it throws (missing plugin class,
/// native load failure, platform exception, ...), record
/// [module] in [log] and return [fallback] instead. The step's
/// own timeouts stay inside the step; this guard is about never
/// letting an exception escape startup.
Future<T> guardStartupStep<T>(
  String module,
  Future<T> Function() step, {
  required T fallback,
  StartupFailureLog? log,
}) async {
  try {
    return await step();
  } catch (_) {
    (log ?? startupFailures).record(module);
    return fallback;
  }
}

/// Chinese announcement naming the failed startup modules.
/// Ends with the honest degradation statement; it never claims
/// a failed module works.
String startupFailureAnnouncement(List<String> modules) {
  if (modules.isEmpty) return '';
  return '启动时有模块不可用：${modules.join('、')}。'
      '应用已降级启动，其余功能可以继续使用；'
      '不可用的模块不会假装正常工作。';
}

/// App entry backstop: run [body] (binding init + runApp) in a
/// guarded zone and capture framework errors. Captured errors
/// are recorded under the module name '应用框架' so the home
/// page can announce them like any other startup degradation.
void runGuardedMain(void Function() body) {
  runZonedGuarded(body, (Object error, StackTrace stack) {
    startupFailures.record('应用框架');
  });
}

/// Install the FlutterError backstop. Call inside the guarded
/// zone, before runApp. The default presentation still happens;
/// the error is additionally recorded for the spoken summary.
void installFrameworkErrorBackstop() {
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    startupFailures.record('应用框架');
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}
