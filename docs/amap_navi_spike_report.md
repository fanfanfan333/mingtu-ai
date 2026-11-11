# NAVHAZ M3：高德 TBT（flutter_amap_navi）spike 评估报告

> 结论先行：**不采用**（大川最终裁示）。本仓不把 `flutter_amap_navi`
> 写进 pubspec、不做构建变体；M3 提交 5 只保留不引依赖的适配层
> （本地样本结构 + 纯映射）、mock 源、§4.4 等价测试与本报告。被移除的
> 插件接入代码存档在 `docs/amap_navi_plugin_integration.md`，不在任何
> 编译路径里。本报告的体积数字来自实下载的插件归档与 SDK jar 的实测
> 构成（本 VM 编不出 APK，未做整包实测）。

## 评估对象

- 插件：`flutter_amap_navi` **1.0.3**（pub.dev，2026-09-14 发布；
  归档下载后 SHA256 与 pub.dev 记录一致）。要求 Dart ≥ 3.12 /
  Flutter ≥ 3.44，本仓 3.47.9 满足。
- 接入形态（spike 期间实测）：三路静态事件流
  （文本 / 定位 / 信息）+ 到达、偏航信号流；初始化要求一个 Dart 侧
  配置对象；启动导航为步行模式。

## 体积：约 35 MB / ABI

插件 Android 侧引入高德导航 SDK 合包
`com.amap.api:navi-3dmap-location-search:11.2.100_3dmap11.2.100_loc11.2.100_sea9.8.1`
（Maven 上为 jar、无传递依赖）。实测构成：

| 项 | 字节 |
|---|---|
| SDK jar 下载体积 | 100,458,122 |
| jar 解压总量 | 204,974,948 |
| arm64-v8a 的 .so（7 个）未压缩 / jar 内压缩 | 87,157,720 / **34,781,386** |
| armeabi-v7a 的 .so（7 个）未压缩 / jar 内压缩 | 63,785,096 / 30,383,480 |
| 非 .so 部分（类/资源）未压缩 / 压缩 | 54,032,132 / 34,163,528 |
| x86_64 的 .so | **无** |
| 插件包本体（pub 归档） | 652,015 |

即单 ABI（arm64）口径约 **35 MB** 量级。而且普通 pubspec 依赖在
构建期就完成插件注册与原生库合并，运行时开关拦不住——「默认关」
省不掉这份体积，真要不进包只能做构建变体，本次明确不做。

## 许可：插件与 SDK 分开看

- **插件本体：BSD 3-Clause**（Copyright 2020 Wenqi Li）——宽松许可，
  这一层没有问题。
- **高德导航 SDK：专有许可**。合包 jar 的 POM 许可声明为高德自有
  条款（Beijing Autonavi Tuqiang Technology Co., Ltd, Version 1.0），
  与插件的 BSD 不是一回事，引入即引入专有 SDK。
- 附带发现（静态，未构建验证）：插件 Gradle 会把
  `com.amap.api:3dmap-location-search` 全局替换为该导航合包；插件
  buildscript 自带 AGP 9.0.1 / Kotlin 2.3.20，与本仓构建存在集成
  风险。

## 剩余距离：可以结构化拿到

这是本次评估最关键的问题，答案是**可以**。信息流名为
`onNaviInfoUpdate`（不是 Change），其载荷含结构化字段：

- `pathRetainDistance`（int，米，**全程剩余**）
- `pathRetainTime`（int，秒，全程剩余时间）
- `curStepRetainDistance`（int，米，当前路段剩余）
- `curStepRetainTime`（int?，秒，当前路段剩余时间）
- 另有 nextRoadName / currentRoadName / curStep 等。

适配层已按这组实测字段定义本地样本结构，并把
`pathRetainDistance` 映射到与 Web 源 `NavigationTracker.remainingM`
同一状态角色上（§4.4 测试 (a) 逐字段断言、(b) 与 Web 源做播报序列
等价断言）。

## key：控制台绑定 SHA1 + 包名，本仓不持有

插件初始化要求配置对象在 Dart 侧必填，key 须先在高德控制台按
**应用包名 + 签名 SHA1** 绑定后，由部署接线层注入。本仓不持有、
不读取、不存放任何 key（控制台配置是部署方的事，也不在本提交
范围内）。

## 界面阻塞项（采用前阻塞）

插件的 `startNavigation` 会拉起**高德自己的原生导航页面**
（插件 manifest 声明了 2 个 Activity）。对盲人用户，这个页面会
抢走本应用的**摄像头 + 按住说话界面**和**音频焦点**——导航播报
与危险提醒都建立在这套界面与音频通道上。这是采用的**前置阻塞
项**，不是细节问题；在它有解法之前，即使其余条件都满足也不能
采用。

## 结论

默认包 +35 MB/ABI、引入专有许可 SDK，只换来一个结构化剩余距离
字段，**不划算**，本次不采用。规格原定的采用条件——「真机能稳定
吐事件才采用」——**未变**，且尚未验证（spike 全程只用 fixture 与
静态源码核查，没有真机事件证据）。保留物（适配层 / mock / 等价
测试）保证将来若条件变化，映射行为已有测试钉死，绑定只需在接缝
处把事件翻译成本地样本。

## 待查项（不在本仓查）

- **高德原生 SDK 有没有无界面（后台）导航模式**——大川另请他人
  查，本仓不查。若有，该模式可能同时解掉界面阻塞项与一部分体积
  问题，届时可重新评估采用。
