# 明途 AI 现有模块地图（重构第一阶段，2026-11-05）

本文件只画“现在有什么”，不画“希望有什么”。不存在的模块不列入已实现。

## 核心（core）

| 文件 | 职责 | 状态 |
|---|---|---|
| `task_manager.dart` | 任务状态机，唯一可信任务状态 | TESTED |
| `speech_scheduler.dart` | 唯一语音出口，3 秒直行、打断、恢复、过期丢弃 | TESTED |
| `risk_engine.dart` | 风险分级 R0–R4，检测/空间置信度分离 | TESTED |
| `route_scoring.dart` | 路线评分，UNKNOWN 永不记安全 | TESTED |
| `llm_gateway.dart` | 本地优先云端网关，预算上限 | TESTED |
| `voice_commands.dart` | 语音指令解析（带我去图书馆/暂停/继续/取消/再说一遍/现在到哪了/帮助/我需要帮助） | TESTED |
| `contracts.dart`（新增） | 统一合同：任务上下文、环境事件、导航指令、用户同意 | TESTED（统一核心测试） |
| `event_bus.dart`（新增） | 统一事件总线：去重、过期丢弃、旧版本丢弃 | TESTED |
| `health_monitor.dart`（新增） | 服务健康与降级播报文案 | TESTED |

## 业务模块（modules）

| 文件 | 职责 | 状态 |
|---|---|---|
| `map_navigation.dart` | 地图桩 + 接近目的地切换 | TESTED（桩数据） |
| `visual_perception.dart` | 检测跟踪去重接口，无模型文件 | TESTED（逻辑） |
| `blind_path.dart` | 盲道优先、杂物多改走人行道、侧方未确认不给步数 | TESTED |
| `entrance_finding.dart` | 入口候选判断，占位数据不能确认入口 | TESTED |
| `indoor_task.dart` | 图书馆服务台任务，需证据才推进 | TESTED |
| `hospital_task.dart` | 医院前置三步，缴费/身份未实现，永不算成功 | TESTED（逻辑） |
| `emergency.dart` | 本地紧急流程，不依赖网络/大模型，永不宣称已联系 | TESTED |
| `recording.dart` | 本地录像保留/删除，等待用户选择 | TESTED |

## 适配器与配置

- `adapters/bailian_client.dart`：百炼文本客户端，Key 本机 `--dart-define`，错误脱敏。真实调用与计费 NOT_VERIFIED。
- `adapters/voice_io.dart`：语音 IO 合同，当前实现 NOT_CONFIGURED。
- `config/app_config.dart`：高德 Key、YOLO 路径、模型 ID 只从 `--dart-define` 读，永不硬编码。

## Skill 注册表（registry，新增）

只注册 12 个真实存在的 Skill：路线规划、户外导航、环境分析、盲道与通道判断、障碍处理、目的地入口定位、室内导航（图书馆）、医院挂号辅助（前置步骤）、紧急求助、录像管理、系统诊断（IMPLEMENTED）、用户反馈收集（NOT_STARTED，默认禁用）。
故意不注册：车站辅助、交通场景评估、医院完整挂号（含缴费/身份）——因为它们不存在，注册就是虚构。

## 演示入口

- `lib/main.dart`：校园图书馆完整演示流程（见 `docs/DEMO_SCRIPT.md`），全部是演示输入与桩数据，不冒充传感器结果。
- `lib/data/verified_locations.json`：全部占位，坐标 null，状态“待现场核验”，等实地核验单填回后才能替换。
