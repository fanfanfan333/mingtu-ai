# 明途 AI v0.4

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
