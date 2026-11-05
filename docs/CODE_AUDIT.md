# 明途 AI 代码审计（重构第一阶段，2026-11-05）

审计范围：`lib/` 全部代码、`test/` 全部测试、现有 docs。
审计结论：核心逻辑完整但模块间没有统一总线；本阶段只加统一层，不重写可用代码。

## 技术栈（已确认）

- Flutter 3.47.9 / Dart 3.13.7（VM 内实测），目标：手机 App 演示原型。
- 无 Android SDK、无 Chrome、无 Linux 桌面工具链（VM 限制，不是项目缺陷）。
- 地图：桩实现（`StubMapProvider`），不是高德 SDK。
- 视觉：本地 YOLO 接口 + 跟踪去重逻辑，无模型文件、无真机推理。
- 语音：演示文本 + 模拟输入，无真实系统 ASR/TTS。
- 云端：百炼 DashScope 文本客户端（v0.2.1），Key 只从本机 `--dart-define` 读。

## 已实现且有测试的模块（TESTED，VM 内）

- 任务状态机 `lib/core/task_manager.dart`：显式迁移、非法拒绝、紧急不自动恢复。
- 语音调度器 `lib/core/speech_scheduler.dart`：单出口、3 秒直行、优先级打断、恢复重确认、过期丢弃、去重。
- 风险引擎 `lib/core/risk_engine.dart`：检测置信度与空间置信度分离，空间阈值 0.6，无可靠空间不给步数。
- 路线评分 `lib/core/route_scoring.dart`：无障碍 UNKNOWN 记满成本，永不记为安全。
- 云端网关 `lib/core/llm_gateway.dart`：本地优先、按需、预算上限 ¥100、拒绝国外高价模型。
- 盲道决策、入口寻找、图书馆室内任务、本地紧急求助、本地录像管理。
- 语音指令解析 `lib/core/voice_commands.dart`、语音 IO 合同 `lib/adapters/voice_io.dart`（NOT_CONFIGURED，不假装）。
- 医院前置三步 `lib/modules/hospital_task.dart`：找挂号处、读机器说明、确认排队位置；缴费/身份未实现，`isFullyCompleted` 恒为 false。

## 审计发现的问题（本阶段处理方式）

1. 各模块各自维护状态，存在互相矛盾的可能 → 本阶段新增统一事件总线、统一合同、健康监控，不删旧模块。
2. 任务状态缺少“准备”和“通用执行” → 状态机新增 `preparing`、`executing`，旧 `planning → navigating` 保留兼容。
3. Skill 只是散落的类，没有注册、启用、前置条件、风险门禁 → 新增 `lib/skills/registry.dart`，只注册真实存在的 12 个 Skill。
4. 服务降级没有统一出口 → 新增 `lib/core/health_monitor.dart`，只报告已上报的服务，不伪造健康。
5. 语音、风险、导航之间的合同是隐式的 → 新增 `lib/core/contracts.dart`（任务上下文、环境事件、导航指令、用户同意）。

## 明确不是审计结论的东西

- 本审计不证明真机可用、地图真实、YOLO 真实、语音真实、道路安全、盲人实测。
- 上述项目仍是 NOT_IMPLEMENTED / NOT_VERIFIED，见 `docs/DEFECTS.md`。
- 任何“已实现”都不自动升级为“已测试”或“已现场验证”。
