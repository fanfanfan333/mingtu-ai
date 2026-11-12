/// Amap navi binding, stub form: the ONLY binding in
/// this build (NAVHAZ M3 final ruling: the evaluated
/// TBT plugin is NOT adopted -- see
/// docs/amap_navi_spike_report.md). Always unavailable
/// and never fakes a navigation event: every start
/// fails cleanly at [UnavailableAmapNaviBinding.
/// initialize], the source reports failure, and the
/// wiring falls back to the Web source. A future real
/// binding, if a later ruling adopts an SDK,
/// translates that SDK's events into the local samples
/// at this same seam.
library;

import '../modules/map_navigation.dart';
import 'amap_navi_source.dart';

class UnavailableAmapNaviBinding implements AmapNaviBinding {
  const UnavailableAmapNaviBinding();

  @override
  Future<void> initialize() async {
    throw StateError('No Amap navi binding is adopted in this build');
  }

  @override
  Stream<String> get textEvents => const Stream<String>.empty();

  @override
  Stream<AmapNaviLocationSample> get locationEvents =>
      const Stream<AmapNaviLocationSample>.empty();

  @override
  Stream<AmapNaviInfoSample> get infoEvents =>
      const Stream<AmapNaviInfoSample>.empty();

  @override
  Stream<bool> get arrivedEvents => const Stream<bool>.empty();

  @override
  Stream<bool> get yawEvents => const Stream<bool>.empty();

  @override
  Future<void> startNavigation({
    required GeoPoint destination,
    required String destinationName,
  }) async {
    throw StateError('No Amap navi binding is adopted in this build');
  }

  @override
  Future<void> stopNavigation() async {}
}

AmapNaviBinding createAmapNaviBinding() => const UnavailableAmapNaviBinding();
