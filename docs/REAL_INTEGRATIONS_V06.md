# 明途 AI 真实接入（v0.6，2026-11-05）

这次把高德、YOLO、真实语音从“接口占位”接成了真代码。
**但“接了代码”不等于“真机已验证”**：云端这台机器没有
Android SDK、没有真机、没有 Chrome，所以下面三项在真机上的
表现只能由用户在自己手机上跑一次才算验证。VM 里验证的是：
代码能编译、测试能通过、没有引擎时诚实报 NOT_CONFIGURED。

## 1. 真实语音（flutter_tts + speech_to_text，系统引擎，免费）

- 代码：`lib/adapters/system_voice_io.dart`。TTS 用 `flutter_tts`
 （zh-CN、语速 0.85），识别用 `speech_to_text`（zh-CN，单次最长
  10 秒、停顿约 3 秒即结束，**不是持续监听**）。识别结果只进
  `parseVoiceCommand`，不直接改状态。
- 接线：`main.dart` 启动时各给 3 秒初始化超时，超时或无引擎就
  留在演示文本播报；有引擎时 `_say` 等 TTS 真正播完才算播完，
  排队的下一条提示也会接着播；引擎中途失败就回退演示播报并
  记录日志，不会卡住。
- 在手机上跑：
  ```sh
  flutter run
  ```
  点“开始语音识别（真机）”，说一句话；再听 TTS 读出“直走”、
  障碍提示、紧急备用办法。算通过：说“停下”立刻暂停，
  说“带我去图书馆”能开始。
- 仍未验证：真机 TTS 音质/语速、嘈杂环境识别率、权限被拒时
  的提示。持续唤醒词“小途”仍未实现（v0.4 已删除的决定不变）。

## 2. 高德步行路线（Web 服务 API，不用 Android SDK）

- 代码：`lib/adapters/amap_client.dart`。GET
  `https://restapi.amap.com/v3/direction/walking?origin=经度,纬度&destination=经度,纬度&key=<Web 服务 Key>&output=json`，
  解析距离、时长、分段指令和折线。Key 只从
  `--dart-define=MINGTU_AMAP_KEY=...` 读，错误信息里 Key 会被
  替换成 `[REDACTED]`。
- 接线：点“高德真实路线”按钮。没有 Key 或没有现场坐标时
  报 NOT_CONFIGURED，不编路线。坐标从
  `--dart-define=MINGTU_AMAP_FROM=经度,纬度`
  `--dart-define=MINGTU_AMAP_TO=经度,纬度` 读，在高德 App 里
  现场读，不凭记忆写。没有 GPS 接入，所以起点不能自动定位。
- 诚实限制：返回的路线仍按无障碍 UNKNOWN 计分（高德不给盲道
  信息），只能写“高德步行路线 + 本地风险规则”，不能写“安全路线”。
- 在手机上跑：
  ```sh
  flutter run \
    --dart-define=MINGTU_AMAP_KEY=你的Key只写在这里 \
    --dart-define=MINGTU_AMAP_FROM=现场起点经度,纬度 \
    --dart-define=MINGTU_AMAP_TO=现场终点经度,纬度
  ```
  先不改代码用浏览器打一次上面那个地址，返回 `status=1` 再点
  按钮。算通过：返回真实距离/分段，路线文字出现在界面上。
- 仍未验证：真机高德调用、真实计费/配额、偏航重规划的
  实测、GPS 定位（未接入）。

## 3. YOLO（ultralytics_yolo 官方插件，手机端推理）

- 代码：`lib/adapters/yolo_detector.dart`（单图推理，条件导入：
  手机用插件，网页用不可用桩，插件没有网页实现，直接 import
  会破坏网页编译）+ `lib/adapters/yolo_live_view.dart`
  （实时摄像头 YOLOView，后置摄像头，GPU 可用时用 GPU）。
  模型默认官方 id `yolo11n`（插件在手机上下载），也可以用
  `--dart-define=MINGTU_YOLO_MODEL_PATH=assets/models/custom.tflite`
  放自己的 `.tflite`。
- 接线：点“打开 YOLO 实时摄像头”，每帧结果映射成
  `Detection`（归一化框中心），进 `VisualPerception.processFrame`
  做跟踪去重（置信度 < 0.3 不成轨）。只报告检测，不给行走
  方向；框的左右绝不直接当成“向左/向右一步”。
- Android：已生成 `android/`（之前项目只有网页），
  `minSdk` 设为 24（插件的 LiteRT 2.3 要求），
  `AndroidManifest.xml` 加了 INTERNET、RECORD_AUDIO、CAMERA、
  定位权限。
- 在手机上跑：`flutter run`（Android 真机，开发者选项开 USB
  调试）。先对着静态的人、自行车、电动车、椅子看检出和单帧
  毫秒数，再实时，最后才边走边测。算通过：能检出、报延迟，
  漏检时系统说“未检测到不等于安全”，而不是“前方安全”。
- 仍未验证：真机模型下载、推理延迟、发热、胸前佩戴抖动和
  光线对检出的影响、iOS（未生成 iOS 工程，比赛先用 Android）。

## VM 里已验证的（2026-11-05）

- `flutter analyze` 无问题；`flutter test` 57/57（新增高德解析/
  无 Key 不联网/Key 不泄漏/状态 0、YOLO 框中心映射、不可用
  检测器不造假 7 个纯 Dart 测试 + 无引擎时语音报不可用、高德
  报缺 Key 1 个 Widget 测试；另修了 v0.6 引入的两个测试问题：
  语音引擎初始化超时、播报完成链导致测试收尾时仍有计时器）。
- `flutter build web` 成功（YOLO 网页桩生效，语音插件用网页实现）。
- `flutter create --platforms=android` 生成的脚手架测试
  `test/widget_test.dart`（计数器示例，与本项目无关）已删除。
