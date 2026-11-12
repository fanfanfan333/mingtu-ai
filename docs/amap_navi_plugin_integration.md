# 存档：flutter_amap_navi 插件接入代码（NAVHAZ M3 TBT spike，未采用）

> 状态：**存档，不是现行代码**。本文件在 `docs/` 下，不在任何编译/分析
> 路径里（不是 `.dart`，analyzer 不拾取）。M3 提交 5 的最终裁示是**不采用**
> 该插件、**不把依赖写进 pubspec**；本文件只保存被移除的接入代码，供将来
> 若有新裁示恢复采用时参考。评估结论见
> `docs/amap_navi_spike_report.md`。

## 为什么移除

- 默认包每 ABI 增加约 35 MB 并引入高德专有许可的导航 SDK，只换来一个
  结构化剩余距离字段，不划算；
- 插件的 `startNavigation` 会拉起高德自己的原生导航页面，对盲人用户会
  抢走本应用的摄像头 + 按住说话界面与音频焦点——采用前阻塞项；
- 规格原定的采用条件（真机能稳定吐事件）尚未验证。

## 恢复方法（仅在新裁示明确采用时）

1. 在 `pubspec.yaml` 的 `dependencies:` 下恢复下面的依赖块（原文），
   再跑 `flutter pub get`（当时实测：lock 仅新增该一条，既有包零版本
   变动；插件要求 Dart ≥ 3.12 / Flutter ≥ 3.44，本仓满足）。
2. 把下面「mobile 绑定全文」存为
   `lib/adapters/amap_navi_source_mobile.dart`，并让
   `lib/adapters/amap_navi_source.dart` 的条件导出在 `dart.library.io`
   时指向它（当时的门面就是这样写的；现行门面已改为无条件导出 stub）。
3. 初始化需要部署方在高德控制台完成配置（包名 + 签名 SHA1 绑定）并把
   配置对象经绑定构造参数的 provider 注入——本仓不持有、不读取任何
   key；provider 未注入时 `initialize` 按设计抛错、源启动失败回退 Web
   源。注意恢复时一并复核「原生导航页面与两区语音界面共存」这一阻塞项
   是否已有解法。

## 被移除的 pubspec 改动（原文）

```yaml
  # NAVHAZ M3 TBT spike (this step): Amap turn-by-turn
  # navigation events as an ALTERNATIVE NavEvent source
  # (see adapters/amap_navi_source.dart). The plugin
  # itself is BSD-3-Clause; its Android side pulls Amap's
  # official PROPRIETARY navigation SDK composite
  # (com.amap.api:navi-3dmap-location-search) under Amap's
  # own SDK terms -- the two licences are different things
  # and are recorded separately in the README. Pinned
  # EXACTLY to the spike-evaluated version. Behind
  # --dart-define=MINGTU_AMAP_NAVI=1 (AppConfig.
  # amapNaviEnabled), OFF by default: while off the source
  # is never constructed and the plugin is never called.
  # NOTE: a plain pubspec dependency is still packaged
  # into the APK while off (plugin registration and native
  # libraries merge at build time); excluding it from the
  # package would need a build flavour, which this spike
  # deliberately does not introduce.
  flutter_amap_navi: 1.0.3
```

## 被移除的 mobile 绑定全文（原文，lib/adapters/amap_navi_source_mobile.dart）

```dart
/// Mobile (dart:io) Amap navi binding over
/// flutter_amap_navi 1.0.3: translates the plugin's
/// event streams into the plugin-free samples the
/// mapping consumes (see amap_navi_source.dart for the
/// verified plugin surface and line references).
///
/// KEY BOUNDARY: AMapNavi.init requires a NaviSdkConfig
/// whose apiKey is a Dart object (the deployer's Amap
/// console key, bound to this app's package name and
/// signing SHA1). That configuration is the deployer's
/// console step: this file holds NO key, reads NO key
/// from anywhere, and defines NO placeholder. While no
/// config provider is injected, [PluginAmapNaviBinding.
/// initialize] throws a StateError and the source's
/// start reports failure, which the wiring treats as
/// "fall back to the Web source". The future deployer
/// wiring injects the provider where
/// [createAmapNaviBinding] constructs the binding.
library;

import 'package:flutter_amap_navi/flutter_amap_navi.dart';

import '../modules/map_navigation.dart';
import 'amap_navi_source.dart';

class PluginAmapNaviBinding implements AmapNaviBinding {
  /// Supplies the SDK init config (including the key)
  /// at start time. Null in this spike: see the file
  /// header. Injected by the deployer's wiring, never
  /// by code in this repository reading a stored value.
  final NaviSdkConfig Function()? sdkConfigProvider;

  bool _initialized = false;

  PluginAmapNaviBinding({this.sdkConfigProvider});

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final NaviSdkConfig Function()? provider = sdkConfigProvider;
    if (provider == null) {
      throw StateError(
        'Amap navi SDK is not configured: the deployer '
        'console step (package name / SHA1 / key) has '
        'not supplied an init config.',
      );
    }
    await AMapNavi.init(config: provider());
    _initialized = true;
  }

  @override
  Stream<String> get textEvents =>
      AMapNavi.onNaviText.map((NaviTextEvent e) => e.text);

  @override
  Stream<AmapNaviLocationSample> get locationEvents =>
      AMapNavi.onNaviLocationChange.map(
        (NaviLocationChangeEvent e) => AmapNaviLocationSample(
          latitude: e.location.position.latitude,
          longitude: e.location.position.longitude,
          accuracyM: e.location.accuracy,
          bearingDeg: e.location.bearing,
          speedKmh: e.location.speed,
          atMs: e.location.time,
          curStepIndex: e.location.curStepIndex,
        ),
      );

  @override
  Stream<AmapNaviInfoSample> get infoEvents =>
      AMapNavi.onNaviInfoUpdate.map(
        (NaviInfoUpdateEvent e) => AmapNaviInfoSample(
          pathRetainDistanceM: e.naviInfo.pathRetainDistance,
          pathRetainTimeS: e.naviInfo.pathRetainTime,
          curStepRetainDistanceM: e.naviInfo.curStepRetainDistance,
          curStepRetainTimeS: e.naviInfo.curStepRetainTime,
          nextRoadName: e.naviInfo.nextRoadName,
          currentRoadName: e.naviInfo.currentRoadName,
          curStep: e.naviInfo.curStep,
        ),
      );

  @override
  Stream<bool> get arrivedEvents =>
      AMapNavi.onNaviArriveDestination.map((_) => true);

  @override
  Stream<bool> get yawEvents =>
      AMapNavi.onNaviReCalculateRouteForYaw.map((_) => true);

  @override
  Future<void> startNavigation({
    required GeoPoint destination,
    required String destinationName,
  }) async {
    await AMapNavi.startNavigation(
      config: NaviConfig(
        naviType: NaviType.walk,
        pageType: NaviPageType.navi,
        end: NaviPoint(
          position: NaviPosition(
            latitude: destination.latitude!,
            longitude: destination.longitude!,
          ),
          name: destinationName,
        ),
      ),
    );
  }

  @override
  Future<void> stopNavigation() => AMapNavi.stopNavigation();
}

/// Factory selected by the conditional export in
/// amap_navi_source.dart. DEPLOYER INJECTION POINT:
/// when the console configuration exists, construct
/// the binding with its sdkConfigProvider here.
AmapNaviBinding createAmapNaviBinding() => PluginAmapNaviBinding();
```
