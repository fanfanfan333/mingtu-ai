# 明途 AI v0.7

## YOLO 模型（assets 内置，2026-11-09）

实时检测模型已打进 APK，不再在手机上下载（旧默认 `yolo11n` 是裸模型 ID，插件会尝试联网下载并失败，真机日志为 `Could not open 'yolo11n'`）。

- **文件**：`assets/models/yolo11n.tflite`（pubspec 已声明；`AppConfig.yoloModelPath` 默认指向它，插件会把 `assets/...` 路径复制到应用文档目录后加载）
- **来源**：Ultralytics 官方 yolo-flutter-app 发布 v0.2.0 的 `yolo11n_int8.tflite`（YOLO11n 目标检测，int8 量化）：https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n_int8.tflite
- **大小**：2831727 字节
- **SHA256**：`414ff688f0c47cbe03cadd3118d22b9024f68e097c8c33bbb25f704d1ca0624d`
- **许可证**：AGPL-3.0（Ultralytics）
- **获取与校验**：构建前运行 `./tool/fetch_model.sh`（下载官方文件并校验大小与 SHA256，不符则拒绝安装）。该二进制不经过普通文本提交通道进仓库，由打包方运行脚本获取；脚本幂等，已存在且校验通过时直接跳过。

模型缺失或加载失败时，应用会在启动汇总里播报“目标检测”不可用，打开实时视图失败时播报“目标检测模型加载失败，YOLO 实时检测不可用”，不会假装检测在工作。

## 构建演示 APK（先看这一节，P0）

**小米 15 等纯 64 位手机必须用 arm64 包。** 教训（2026-11-09 真机反馈）：把只含 armeabi-v7a（32 位）的 APK 装到纯 64 位手机上，能安装、但一打开就退出——32 位 Flutter 引擎在纯 64 位系统上无法加载。不要用 `--target-platform android-arm` 打演示包。

```bash
# 64 位手机（小米 15 等，演示首选）：
flutter build apk --release --target-platform android-arm64

# 通用包（同时含 arm64-v8a 与 armeabi-v7a，体积更大）：
flutter build apk --release

# 分 ABI 构建（每个 ABI 一个包，其中包含 arm64-v8a）：
flutter build apk --release --split-per-abi
```

ABI 由构建命令决定，工程里**不写死 `ndk.abiFilters`**（写死会与 `--split-per-abi` 冲突）：`--target-platform android-arm64` 出纯 64 位包；`--split-per-abi` 出分 ABI 的多个包（其中就有 arm64-v8a）；不带参数出同时含 64/32 位的通用包。构建时按需追加演示参数（值用占位符，勿把真值写进任何文档/仓库）：

**体积与 ABI 完整性（如实记录）**：演示包请只用 `--target-platform android-arm64` 构建——这种包里只有 arm64 的 `libapp.so`/`libflutter.so` 是完整的，**不要把它装到 32 位（armeabi-v7a）或 x86_64 设备/模拟器上，会崩**；需要多 ABI 就用通用包命令（每个 ABI 的 so 都完整，但体积更大）。`useLegacyPackaging`（压缩 .so）在 229601e 试过，Codex 实测带演示 key 的构建反而涨到 **38.4MB**，故已移除、不再使用；当前控体积的唯一手段就是单 ABI arm64。

```bash
flutter build apk --release --target-platform android-arm64 \
  --dart-define=MINGTU_AMAP_KEY=<演示高德key，演示后作废> \
  --dart-define=MINGTU_VISION_PROXY_URL=<识图FC的https地址> \
  --dart-define=MINGTU_VISION_TOKEN=<演示令牌，演示后作废>
```

## 演示直连模式与密钥警告（2026-11-09，用户决定）

- 演示版可把高德 Web 服务 Key 通过 `--dart-define=MINGTU_AMAP_KEY=...`
  在**构建时**注入，实现客户端直连高德步行路线（结构化解析与代理
  模式完全一致：枚举动作、有界数值、严格 polyline、中文由本端模板
  生成；超时/失败中文播报并降级）。仓库里绝不保存 key 值；不传时
  仍走自建代理或未配置，启动导航时会中文播报当前模式。
- **警告：编译进 APK 的 key 可以被提取。** 该演示 key 仅供演示，
  **演示结束后必须由用户在高德控制台重新生成/作废**，不得用于
  正式发布。正式版的 key 只放在自建代理的服务器环境变量里
  （见 `server/README.md`）。百炼 key 不进 APK，只走代理/本机网关。

## 摄像头取消的诚实边界（2026-11-09）

- 云端视觉识别与摄像头占用的取消是**协作式**的：应用进入后台或
  销毁时，我们取消令牌、丢弃迟到结果、不再播报，并启动摄像头
  释放；但已经发出的平台调用（枚举摄像头、初始化、拍照、
  dispose）不会被物理中断，要等它自己返回后释放才算完成。
  下一次获取摄像头会先等这次释放完成（超时则拒绝并播报
  “摄像头忙，请稍后再试”）。物理中断能力需真机验证，本条不
  声称已验证。


## v0.7（2026-11-05）新增：语音功能按用户原话再核对——盲人不用点屏幕也能用

- 健康降级播报改中文服务名，不再读出 map_navigation、voice_output 这类英文。
- 高德路段能语音播报：取路线播报第一段，导航中说“下一步”逐段播报，播完会说没有下一段了。
- 免点按语音入口：启动后 TTS 问候，随后自动开始一次识别；每条播报说完自动再听，任务进行中随时可说指令；监听只在播报结束后开始，不会把 TTS 自己的声音当成指令；点“停止语音识别”关闭自动再听。持续唤醒词仍未实现，替代就是这个轮流对话。
- YOLO 真实检测进风险/语音：新跟踪到行人/自行车/汽车等时播报并停直行，连续 3 帧无目标才解除，不自动恢复直行；导航中说“继续”可重新确认直行。导航开始自动打开摄像头，紧急和完成时关闭。
- 对照表见 `docs/VOICE_AUDIT_V07.md`；仍不符合的（联系帮扶站、医院完整挂号、红绿灯放行、相册导出、GPS）本次不冒充，见 `docs/DEFECTS.md`。
- 验证（VM 内，2026-11-05）：`flutter analyze` 无问题，`flutter test` 62/62，`flutter build web` 成功；真机语音、识别率、YOLO 延迟仍未验证。

## v0.6（2026-11-05）新增：高德、YOLO、真实语音接成真代码（真机待验证）

- 真实语音：`flutter_tts`（系统 TTS，zh-CN）+ `speech_to_text`（系统识别，单次最长 10 秒，非持续监听）；播报等 TTS 真正播完才算播完，引擎失败回退演示播报；无引擎时报 NOT_CONFIGURED。
- 高德：Web 服务步行路线 REST 客户端，Key 与现场坐标只从 `--dart-define` 读；无 Key/无坐标不编路线；真实路线仍按无障碍 UNKNOWN 计分，不宣称“安全路线”。
- YOLO：官方 `ultralytics_yolo` 插件，单图推理 + 实时摄像头视图（条件导入，网页用桩）；模型默认 `yolo11n`，结果进跟踪去重，只报告检测，不给行走方向。新增 `android/` 工程（minSdk 24，相机/录音/定位权限）。
- 接入说明与真机跑法见 `docs/REAL_INTEGRATIONS_V06.md`；**真机调用、延迟、识别率都仍未验证**，只能在用户手机上跑一次才算数。
- 验证（VM 内，2026-11-05）：`flutter analyze` 无问题，`flutter test` 57/57，`flutter build web` 成功；网页产物未在浏览器中点按验证，真机/Android 构建仍未做。

## v0.5（2026-11-05）新增：盲人优先再审计——看不见屏幕也能安全用

- 修了一个 v0.4 引入的危险 bug：避障提示在转弯播报时会被丢弃，现在高优先级避障打断转弯，低优先级转弯在避障时才丢弃。
- 状态播报和界面状态行全部改中文，不再读出 understanding、paused 这类英文枚举名。
- 新增语音指令：停下、别走了、我在哪、前面有什么、确认 / 我到了 / 下一步、保存录像、删除录像；室内步骤和录像保存/删除不再只能点按钮。
- 紧急播报全文含备用办法，健康降级在任务开始时语音告知，状态查询追加路线信息。
- 审计清单见 `docs/BLIND_AUDIT_V05.md`；仍未验证的真机项目见 `docs/DEFECTS.md`。
- 验证（VM 内，2026-11-05）：`flutter analyze` 无问题，`flutter test` 49/49，`flutter build web` 成功；网页产物未在浏览器中点按验证，真机/高德/YOLO/真实语音/实地验证仍未做。

## v0.4（2026-11-05）新增：按总规范整改——能做就修，不能做就删，不留假功能

- 可行性评估见 `docs/FEASIBILITY.md`：15 个模块逐个判可做 / 可替代 / 删除。
- 修：统一任务上下文快照、Skill 注册表接进演示（路线规划走门禁）、健康覆盖（演示开始上报地图桩/演示语音/无摄像头）、交通与位置不确定永不给步数、转弯与避障冲突指令丢弃不连播、偏航重规划需精度合格、低置信度检测不建轨迹。
- 替代：路口过街决策删掉，换成只提示不放行的 `traffic_scene.dart`（`allowsCrossing` 恒 false）；持续学习自动改规则删掉，换成只记录的 `learning_backlog.dart`（无 `apply()`）。
- 删除（本版不宣称、不留假入口）：持续唤醒词、云端视觉传图、车站 Skill、医院完整挂号、呼叫帮助站、保存到相册——其中后两者在代码里明写 NOT_CONFIGURED / 永不宣称已联系。
- Skill 注册表从 12 个变 13 个：新增 `traffic_scene_info`，车站仍未注册。
- 验证（VM 内，2026-11-05）：`flutter analyze` 无问题，`flutter test` 46/46（35 旧 + 11 个 v0.4 新测试），`flutter build web` 成功；网页产物未在浏览器中点按验证，真机/高德/YOLO/真实语音/实地验证仍未做。

## v0.3（2026-11-05）新增：重构第一阶段——统一层，不扩场景

- 统一合同 `lib/core/contracts.dart`、统一事件总线 `lib/core/event_bus.dart`、健康监控 `lib/core/health_monitor.dart`、Skill 注册表 `lib/skills/registry.dart`（只注册 12 个真实 Skill，车站/交通场景故意不注册）。
- 任务状态机新增 `preparing`、`executing`，旧 `planning → navigating` 保留兼容，紧急不自动恢复不变。
- 演示入口接线：语音播报发布 `speechRequested` 事件，紧急发布 `emergencyTriggered` 事件并上报本地紧急服务健康；界面新增系统健康显示（无上报时不伪造健康）。
- 审计文档：`docs/CODE_AUDIT.md`、`EXISTING_MODULE_MAP.md`、`TECHNICAL_DEBT.md`、`REFACTOR_PLAN.md`、`BLIND_FIRST_DESIGN.md`；每项功能仍按 NOT_STARTED / IMPLEMENTED / TESTED / FIELD_VALIDATED 诚实标注，不自动升级。
- 验证（VM 内，2026-11-05）：`flutter analyze` 无问题，`flutter test` 35/35（29 旧 + 6 统一核心新测试），`flutter build web` 成功；网页产物未在浏览器中点按验证，真机/高德/YOLO/真实语音/实地验证仍未做。
- 本批本地已验证，未推送：需用户在场确认后推 main，核验远端头并回读新文件后才算推完。

## v0.2.2（2026-11-05）新增：盲人第一缺陷补齐

- 语音控制：新增 `lib/core/voice_commands.dart`，支持带我去图书馆、暂停、继续、取消、再说一遍、现在到哪了、帮助、我需要帮助；非法迁移只回答不执行，紧急永不自动恢复。
- 暂停会停直行计时器，继续不自动重启直行，必须重新确认直行路段；上一条提示可以重听。
- 医院挂号：从一句占位补成前置引导三步（找挂号处、读机器说明、确认排队位置），每步需核验；缴费 / 身份核验仍未实现，所以永远不算挂号成功。
- 语音输入输出合同：新增 `lib/adapters/voice_io.dart`，明确系统 TTS / ASR 还没接入，当前只报 NOT_CONFIGURED，不假装会说话。
- 缺陷清单见 `docs/DEFECTS.md`：已补和仍开放分开写，真实 TTS / ASR、摄像头、GPS、高德、YOLO、红绿灯、真实挂号缴费、实地验证仍开放，不冒充已补。

## v0.2.1（2026-11-05）新增：百炼客户端（Key 不发给 Muse）

- 新增 `lib/adapters/bailian_client.dart`：阿里云百炼 DashScope OpenAI 兼容接口客户端，见 `docs/BAILIAN.md`。
- Key 只从本机 `--dart-define=MINGTU_DASHSCOPE_API_KEY` 读，代码里不写、不打印、不提交；学生券是账号级的，挂在用户自己的百炼账号上，不经过 Muse。
- 只有网关先批准（本地先试过且不够用、预算内）才发请求；没 Key、网关拒绝、预算不足时不发网络请求。报错时 Key 会被替换成 `[REDACTED]`。
- 演示界面新增“百炼真实调用”按钮：只有用户主动点按、且本机已配置 Key 时才真正调用一次；原来的“云端网关演示”按钮仍只返回决策，永不产生费用。
- 测试：新增 `test/bailian_client_test.dart`（4 个测试，假发送器，零真实费用），`flutter test` 24/24，`flutter analyze` 无问题。
- 还没验证：真实百炼调用和真实计费，只能在用户本机带 Key 跑一次后才算验证；视觉传图还没做，现在只发文本。

## v0.2（2026-11-05）新增：可运行的演示流程

v0.2 把 v0.1 的静态状态展示升级为完整的语音优先演示流程
（见 docs/DEMO_SCRIPT.md），只用已有核心逻辑实现：

- 语音开始（演示输入）→ 理解并规划路线 → 开始导航
  → 直行 3 秒节奏 → 转弯与直行恢复 → 侧方未确认障碍（停下，
  不给步数）→ 侧方已确认障碍（仅演示数据给一步，播报完成
  不等于动作完成）→ 接近目的地 → 入口寻找 → 室内服务台任务
  → 任务验证 → 任务完成 → 本地录像保留/删除
  → 云端网关演示（只返回决策，无真实调用）
  → 本地紧急求助（不依赖网络和大模型，不宣称已联系帮助站）
- 新增 lib/config/app_config.dart：高德密钥、YOLO 模型路径、
  LLM 模型 ID 只来自 --dart-define，永不硬编码、永不提交；
  未配置时对应能力显示 NOT_CONFIGURED，绝不伪造路线、检测或语音结果。
- 新增 web 平台支持，`flutter build web` 已成功，输出在 build/web
 （构建产物不提交，见 .gitignore）。
- 新增两个 Widget 测试，覆盖演示主流程和完整流程。

v0.2 实际运行结果（2026-11-05，VM 内）：

- Flutter 3.47.9（stable），Dart 3.13.7，SDK 装在 VM 外的
  ~/flutter-sdk（不在项目内，不提交）。
- `flutter test`：20/20 通过（18 个核心测试 + 2 个 Widget 测试）。
- `flutter analyze`：No issues found!（0 个问题）。
- `flutter build web`：✓ Built build/web（build/web/index.html，
  main.dart.js 约 2.0 MB，build/web 共约 40 MB）。
- `flutter doctor`：Flutter 本身通过；VM 内缺少 Android SDK、
  Chrome 和 Linux 桌面工具链（clang、ninja、GTK），
  所以 Android 真机、Chrome 运行和 Linux 桌面构建未在本机验证。
- 网页构建产物未在本机浏览器中实际打开运行（VM 内无 Chrome），
  不能宣称为“已在浏览器中点按验证”；Widget 测试已验证主流程
  的按钮驱动状态变化。

## 明途是什么

明途 AI 是面向视障人士的校园出行辅助演示原型，参加学生比赛用。它的定位是**辅助工具**，不是独立出行工具。

一句话：用户用语音说目的地，系统用地图规划路线、用摄像头感知环境、用语音给出可执行提示，并在一个校园图书馆场景里走完“出发、导航、找入口、找服务台标识、确认完成”的完整流程。

## 盲人优先原则（不可妥协）

- 核心操作必须能只靠语音完成，不能要求用户看屏幕点按钮。
- 语音是唯一播报出口：所有模块都向语音调度器提交，任何模块不得直接调用 TTS。
- 直行提示只在确认是直线路段时才按 3 秒节奏播报，高优先级提示打断后必须重新确认状态才能恢复，过期提示永不补播。
- 侧方空间无法确认时，绝不给出向左或向右迈步指令，只给停下或求助提示。
- 没检测到障碍，不等于前方安全；语音说完了，不等于用户动作完成了。
- 紧急求助必须能在本地启动，不依赖云端大模型和网络。
- 任务完成必须靠实际状态验证，地图显示到了不等于进了门，流程走完了不等于任务成功了。

## v0.2 做什么（一个场景）

只做校园图书馆场景：起点、转弯点、图书馆入口、服务台标识。包含：

- 任务状态机（显式状态迁移，非法迁移拒绝）
- 统一语音调度器（优先级、打断、恢复、去重、过期丢弃）
- 风险引擎（检测置信度与空间置信度分离，R0-R4）
- 路线评分（距离、时间、无障碍缺失成本、已知风险成本；无障碍未知记为 UNKNOWN，永不记为安全）
- 本地优先的云端网关（按需调用、预算上限、拒绝国外高价模型）
- 地图接口占位、本地 YOLO 检测接口（检测、跟踪、去重）
- 盲道决策、入口寻找、图书馆室内任务、本地紧急求助、本地录像管理
- 仅有的三个 Skill：路线规划、环境分析、目的地寻找

## 明确没有实现、没有验证的东西

| 项目 | 状态 |
|---|---|
| 任务状态机、语音调度器、风险引擎、路线评分、云端网关、盲道决策、入口寻找、图书馆室内任务、紧急求助、录像管理、三个 Skill | IMPLEMENTED（代码已写，见测试运行结果） |
| 上述核心逻辑的单元测试 | TESTED：2026-11-05 在 VM 内用 Dart SDK 3.13.7 独立包验证，18/18 通过（见 TEST_RUN_LOG.txt）；`flutter test` 未运行（本机无 Flutter SDK），Flutter UI 未编译验证 |
| Flutter 网页构建（build/web）与 Widget 演示流程 | TESTED：2026-11-05，flutter test 20/20，flutter analyze 0 问题，flutter build web 成功；网页产物未在本机浏览器中打开运行 |
| Flutter 真机运行、语音识别与合成接入、高德地图 SDK 真实接入、本地 YOLO 模型文件与手机端推理、摄像头与定位真机验证 | NOT_IMPLEMENTED（仍需用户手机、高德密钥、YOLO 模型文件和现场核验地点） |
| 医院挂号完整流程 | NOT_IMPLEMENTED（仅接口占位，见 lib/skills/hospital_registration.dart） |
| 真实道路安全、精确迈步指令的空间验证、红绿灯过街许可 | NOT_IMPLEMENTED / NOT_VERIFIED，绝不能宣称 |
| 真实视障用户参与的受控可用性验证 | NOT_IMPLEMENTED（未做，不虚构） |
| 演示视频、模拟结果 | 无。本仓库目前没有演示视频，任何演示视频都必须标注为受控环境演示 |

明途不能替代盲杖、导盲犬或专业定向行走训练。任何对外材料都必须保留这句话。

## 测试运行结果（已实际运行，非宣称）

### v0.2（2026-11-05，最新）

- `flutter test`：20/20 通过（见 TEST_RUN_LOG.txt v0.2 节）。
- `flutter analyze`：No issues found!
- `flutter build web`：✓ Built build/web。
- 未验证：真机运行、高德/YOLO/语音/摄像头/定位真机验证、
  网页产物浏览器内点按运行、真实道路安全、真实视障用户验证。

### v0.1（2026-11-05，历史）

- 时间与环境：2026-11-05，VM 内下载的 Dart SDK 3.13.7（stable），独立测试包（复制 lib/ 与 test/，仅依赖 package:test）。
- 结果：**18/18 通过**，包括任务状态机 4 项、语音调度器 4 项、风险引擎 5 项、路线评分 2 项、云端网关 3 项。完整输出见 TEST_RUN_LOG.txt。
- 未运行：`flutter test`（本机无 Flutter SDK，未安装）；`lib/main.dart` 的 Flutter UI 未编译、未在真机或模拟器上运行；高德、YOLO、语音、摄像头、定位均未真机验证。
- `dart analyze` 在独立包中除 `lib/main.dart` 的 Flutter 导入缺失（独立包无 Flutter SDK，预期内）外，核心与模块文件无错误。

## 如何运行

需要 Flutter SDK（见 scripts/run_tests.sh）：

```sh
flutter pub get
flutter test
flutter analyze
flutter run
```

只构建网页演示产物（不提交 build/）：

```sh
flutter build web
# 输出：build/web（用静态服务器托管，或在装有 Chrome 的机器上 flutter run -d chrome）
```

配置（只用 --dart-define，永不写进代码或提交）：

```sh
flutter run --dart-define=MINGTU_AMAP_KEY=... \
  --dart-define=MINGTU_YOLO_MODEL_PATH=... \
  --dart-define=MINGTU_LLM_MODEL_ID=...
```

只验证核心逻辑（不需要 Flutter UI）：

```sh
bash scripts/run_tests.sh
```

该脚本会先尝试 `flutter test`，如果本机没有 Flutter，会尝试用 Dart 独立测试包验证核心逻辑；两种方式都不可用时，脚本会明确失败，不会假装通过。

## 如何替换占位地点数据

`lib/data/verified_locations.json` 里的所有条目都是占位，坐标为 null，状态全部是“待现场核验”，没有任何真实地点、无障碍信息或入口信息。现场核验后才能：

1. 填写实地确认的地点名称和特征；
2. 填写经实地确认的坐标（不要凭记忆编）；
3. 把状态从“待现场核验”改为“已现场核验”，并注明核验日期和核验人；
4. 未经核验的条目不得用于入口确认（入口寻找模块会拒绝仅凭占位数据确认入口）。

## 预算

上限 100 元人民币，本地优先、云端按需，详见 docs/BUDGET.md。云端只在本地不足时触发，旗舰模型、国外高价模型、服务器、智能眼镜、GPU 训练均不在 v0.1 预算内。

## 文档

- docs/PRODUCT_REQUIREMENTS.md：产品需求
- docs/SYSTEM_ARCHITECTURE.md：系统架构
- docs/MODULE_CONTRACTS.md：模块接口
- docs/SAFETY_REQUIREMENTS.md：安全要求
- docs/TEST_PLAN.md：测试计划
- docs/BUDGET.md：预算
- docs/SUBMISSION_CHECKLIST.md：提交清单
- docs/DEMO_SCRIPT.md：3 分钟演示脚本（模拟与真实的对照表）
- lib/config/app_config.dart：--dart-define 配置（无硬编码密钥）
