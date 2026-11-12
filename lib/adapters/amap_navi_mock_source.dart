/// TEST SUPPORT ONLY -- scripted mock source for the
/// Amap TBT adapter (NAVHAZ M3). This file is NOT
/// referenced by lib/main.dart or by any production
/// wiring; it exists so tests can drive
/// [AmapNaviSource] with a deterministic script of
/// locally defined samples (no plugin, no platform
/// channel, no network). The samples use the exact
/// local structs from amap_navi_source.dart, so a test
/// written against this mock exercises the same
/// mapping a future real binding would feed.
library;

import 'dart:async';

import '../modules/map_navigation.dart';
import 'amap_navi_source.dart';

/// The kind of sample one script step delivers.
enum AmapNaviMockStepKind { text, location, info, arrived, yaw }

/// One scripted delivery: [kind] selects the stream,
/// and exactly the fields for that kind are read
/// (text -> [text]; location -> [location];
/// info -> [info]; arrived / yaw -> the signal fires
/// with value true). [after] is the delay before this
/// step is delivered, applied when the binding's
/// startNavigation runs; zero-delay scripts complete
/// on microtask turns, in script order.
class AmapNaviMockStep {
  final AmapNaviMockStepKind kind;
  final String? text;
  final AmapNaviLocationSample? location;
  final AmapNaviInfoSample? info;
  final Duration after;

  const AmapNaviMockStep._(
    this.kind, {
    this.text,
    this.location,
    this.info,
    this.after = Duration.zero,
  });

  const AmapNaviMockStep.text(String text, {Duration after = Duration.zero})
      : this._(AmapNaviMockStepKind.text, text: text, after: after);

  const AmapNaviMockStep.location(AmapNaviLocationSample sample,
      {Duration after = Duration.zero})
      : this._(AmapNaviMockStepKind.location, location: sample, after: after);

  const AmapNaviMockStep.info(AmapNaviInfoSample sample,
      {Duration after = Duration.zero})
      : this._(AmapNaviMockStepKind.info, info: sample, after: after);

  const AmapNaviMockStep.arrived({Duration after = Duration.zero})
      : this._(AmapNaviMockStepKind.arrived, after: after);

  const AmapNaviMockStep.yaw({Duration after = Duration.zero})
      : this._(AmapNaviMockStepKind.yaw, after: after);
}

/// A scripted [AmapNaviBinding] fake: initialize /
/// start / stop are counted, the start destination is
/// recorded, and [script] is replayed into the sample
/// streams when startNavigation is called. With
/// [failInitialize] set, initialize throws (the
/// scripted-failure shape used by the fallback tests).
class MockAmapNaviBinding implements AmapNaviBinding {
  final List<AmapNaviMockStep> script;
  final bool failInitialize;

  int initializeCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  GeoPoint? startedDestination;
  String? startedDestinationName;

  final StreamController<String> _text = StreamController<String>();
  final StreamController<AmapNaviLocationSample> _location =
      StreamController<AmapNaviLocationSample>();
  final StreamController<AmapNaviInfoSample> _info =
      StreamController<AmapNaviInfoSample>();
  final StreamController<bool> _arrived = StreamController<bool>();
  final StreamController<bool> _yaw = StreamController<bool>();

  MockAmapNaviBinding(this.script, {this.failInitialize = false});

  @override
  Future<void> initialize() async {
    initializeCalls += 1;
    if (failInitialize) {
      throw StateError('mock binding: initialize failed (scripted)');
    }
  }

  @override
  Stream<String> get textEvents => _text.stream;

  @override
  Stream<AmapNaviLocationSample> get locationEvents => _location.stream;

  @override
  Stream<AmapNaviInfoSample> get infoEvents => _info.stream;

  @override
  Stream<bool> get arrivedEvents => _arrived.stream;

  @override
  Stream<bool> get yawEvents => _yaw.stream;

  @override
  Future<void> startNavigation({
    required GeoPoint destination,
    required String destinationName,
  }) async {
    startCalls += 1;
    startedDestination = destination;
    startedDestinationName = destinationName;
    for (final AmapNaviMockStep step in script) {
      if (step.after > Duration.zero) {
        await Future<void>.delayed(step.after);
      }
      switch (step.kind) {
        case AmapNaviMockStepKind.text:
          _text.add(step.text!);
        case AmapNaviMockStepKind.location:
          _location.add(step.location!);
        case AmapNaviMockStepKind.info:
          _info.add(step.info!);
        case AmapNaviMockStepKind.arrived:
          _arrived.add(true);
        case AmapNaviMockStepKind.yaw:
          _yaw.add(true);
      }
    }
  }

  @override
  Future<void> stopNavigation() async {
    stopCalls += 1;
  }
}

/// A ready-made (binding, source) pair over one
/// script, so a test can both drive the source and
/// inspect what the binding was asked to do.
class ScriptedAmapNaviScenario {
  final MockAmapNaviBinding binding;
  final AmapNaviSource source;

  ScriptedAmapNaviScenario._(this.binding, this.source);

  factory ScriptedAmapNaviScenario(
    List<AmapNaviMockStep> script, {
    DateTime Function()? clock,
    bool failInitialize = false,
  }) {
    final MockAmapNaviBinding binding =
        MockAmapNaviBinding(script, failInitialize: failInitialize);
    return ScriptedAmapNaviScenario._(
      binding,
      AmapNaviSource(binding: binding, clock: clock),
    );
  }
}
