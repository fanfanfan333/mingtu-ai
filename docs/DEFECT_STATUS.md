# 明途 AI 缺陷状态（2026-11-16 收尾）

本文只记录**当前代码状态**，与 `docs/DEFECTS.md`（v0.2–v0.7 的历史修复记录）分工不同：
`DEFECTS.md` 讲当时补了什么，本文讲**现在还有什么没解决、以及凭什么说某个问题解决了**。

验收口径沿用仓库既有约定：
- **已修** = 代码已改 + 有自动化测试 + 做过反向验证（改坏会红）+ 全量绿。
- **待真机** = 代码路径存在但无法在本机证伪，不得在交付材料里写成已验证。
- **已知限制** = 有意不做或做不了，如实声明，不冒充。

---

## 一、本轮已修复（含可证伪证据）

### 1. 危险仍在时补播「继续直走」（安全缺陷，最严重）

- **现象**：危险播报打断导航提示后，恢复时的实际播报序列是
  `语音已恢复。 → 停，前方来车。 → 继续直走 → 用盲杖确认。`
  车还在正前方、任务仍是 `avoidingObstacle`，却让盲人「继续直走」。
- **根因**：`_finishSpeech` 的重放路径只判 `!_dangerPending`（没有危险播报在排队），
  **漏判 `_riskActive`**（危险是否仍在）。同一文件里 `promoteNext(riskActive:)` 与
  `Pacing.recheck(riskActive:)` 都硬拦 riskActive 下的 straight，唯独这条
  `_say(replay)` 直发路径绕过了守卫——是漏守卫，不是策略选择。
- **修复**（`878dec5`）：新增 `_tryReplayInterruptedNav()`，危险仍在且队首是 straight 时
  压住不重放；`_pendingInterruptedNavReplay` 让每次播报完成后重试，危险经
  `_exitYoloRiskState` 解除时必播「前方已无检测到的障碍…」，该句完成即补播点；
  只压 straight，不压 turn/offroute；15 秒窗口与用户暂停丢弃策略未改。
- **证据**：`navhaz_arbitration_test`、`navhaz_arb_15s_expiry_test` 改为双向断言
  （危险中 `isEmpty('继续直走')` → 解除后 `contains('speak:继续直走')`）。
  撤掉 `_riskActive &&` 两条立即变红；修复前 `tts_recovery_test` 的直走禁令同样变红。
- **注意**：这条是**补强测试断言时**才暴露的——原断言在危险仍在时就要求
  `contains('继续直走')`，等于测试本身在纵容这个缺陷。原断言已收紧。

### 2. 同一故障被反复补报（去重无语义覆盖）

- 拆掉 `_deliveredRecoveryFaults` 去重后，原有用例全绿——核心承诺没人守。
- 已补用例；实测拆去重后同一文本被播报 **73 次**（断言期望 1 次）。`c343a74`

### 3. 演示包静默缺失路线配置

- 路线/识图配置全是 `String.fromEnvironment` 编译期常量，原打包脚本既不注入也不校验，
  产出过「能装能启动、一进导航就播报路线不可用」的包。
- 修复（`0618c16`）：`tool/build_release_apk.sh` 支持本地配置文件/环境变量注入，
  构建后解 `lib/arm64-v8a/libapp.so` 逐项字节校验值确实进包（缺一项 exit 1），
  缺路线双键时告警并写 `*.NOTICE.txt`，`--require-routes` 直接失败。
- 实测三态：无配置→告警+NOTICE；假值注入→`[OK] 已进包`；`--require-routes`→EXIT=1。

### 4. manifest 发布门禁硬编码 CI 路径

- **现象**：`test/ui_07_m1_test.dart` 的 `manifest removes permissions and services`
  只在 release 产物存在时才激活；一旦真的构建过包，本机报
  `find: /workspace/tools/android-sdk/build-tools: No such file or directory`。
  这是被「无产物」守卫长期掩盖的脚本缺陷，不是环境噪声。
- 修复（`0618c16`）：改为尊重 `ANDROID_SDK_ROOT`/`ANDROID_HOME`，Windows 用 `cygpath`
  转路径，未设置时回退原 CI 路径；**只匹配 `aapt`，显式不匹配 `aapt2`**
  （aapt2 的 `dump xmltree` 参数顺序不同，混用会静默产出错误结论）。

### 5. Windows 中文路径打不出包

- AGP 拒绝非 ASCII 路径；junction 会被 Gradle 解析回真实路径；加
  `android.overridePathCheck` 只能盖住第一层，之后 Gradle 调 `flutter.bat` 时路径按 GBK
  解读成乱码、报 `Unable to read file: ...app.dill`。必须在纯 ASCII 目录构建。
- 修复（`54d2eaa`）：`tool/build_release_apk.sh` 自动镜像到 ASCII 目录构建后拷回。
  **不要**加 `android.overridePathCheck`。

### 6. Codex 记录的两个遗留失败（已确认修好，非 flaky）

- `recovery when hazard remains during TTS failure`（期望 `avoidingObstacle`，实际 `navigating`）
- `danger is replayed before camera fault after TTS recovery`（危险播报整条丢失，`indexWhere` 返回 -1）
- **根因**：G27 之前 YOLO 帧时钟用 `DateTime.now()`，危险短语按**真实时间**过期；
  机器一慢就等价于「危险已解除」，同时产出上述两个现象。
- **证据**：QA 独立复跑 单用例各 25 次 + 整文件 450+ 次用例执行，零失败；
  断言文本自 `41e5a8c` 起逐行未改（只多了帧时钟注入），不是改断言迁就实现。

### 7. 用户说「停下」后中断队列未清空（防御性加固，非当前可达故障）

- **不一致点**：`_stopSpeechThenConfirm` 只清了 `_pendingInterruptedNavReplay`，而
  `SpeechScheduler.cancelAll()` 只清 `_active`/`_queue`，**不清 `interruptedRequests`**。
  于是「用户说停下后不再补播任何被压住的导航提示」这句注释与实现不符。
- **诚实说明**：QA 指出的端到端路径（停下 → 危险播报完成 → 解除 → 补播「继续直走」）
  在当前代码里**不可达**——停下后 `_hazardWatchActive` 为 false，危险播报不再发出；
  紧急求助又会把 `_yoloRiskActive` 置 false，因此不会出现「`_riskActive` 由 true 变 false
  触发补播」的时刻。实测撤掉本项改动，纯端到端断言仍然绿。
- **所以本项性质是**：让实现与既有注释承诺一致 + 消除未来重排代码时的风险，
  **不是**修复一条当前可达的用户可见故障。红/绿锚点落在契约本身。
- **改动**（`878dec5` 之后）：新增 `SpeechScheduler.discardAllInterrupted()`
  （不改 `cancelAll` 本身，它被紧急等场景复用），清 `interruptedRequests` 与
  `_interruptedAt`，id 记入 `cancelledLog`；新增用例
  `(c3) a user stop discards the interrupted straight for good` 断言停下后
  中断队列为空、且此后不再出现任何「直走」。

---

## 二、必须真机 / 云电脑验证（本机无法证伪，不得写成已验证）

1. **TalkBack 焦点顺序、整屏按住说话手势、振动波形**（起一下、止两下）、
   **耳机按键分发**——Kotlin 侧已确认编译进包（`classes2.dex` 内可检出
   `mingtu/device` 与 `HeadsetKeyFilter`），但**编译通过不等于行为正确**。
2. **Android TTS `stop()` 返回后旧 `onStop` 回调晚到**的时序——独立审查提出，
   单测用 Fake 无法覆盖原生时序，未排除。影响：旧回调可能干扰新的危险播报。
3. **YOLO 真机延迟、漏检率、发热降频**；坑洞检测器（默认关）的误报率。
4. **高德路线**：客户端已支持直连与自建代理两种模式，但当前演示包**未注入任何路线配置**，
   发布可用的路线服务尚未部署。
5. **模拟 GPS 跑导航、有标注的录像回放**——本项目只有未标注录像的单次采样，
   不能据此算准确率/漏报率。

---

## 三、已知功能限制（如实声明，不冒充已实现）

- **持续唤醒词「小途」未实现**：替代方案是启动问候 + 每次播报后自动再听（轮流对话）。
- **医院完整挂号未实现**：只有前置三步引导，缴费与身份核验未做，`isFullyCompleted` 恒 false。
- **录像导出相册** `NOT_CONFIGURED`：只保存本地演示会话。
- **红绿灯放行**恒 false：只提示，不放行。
- **联系残障帮扶站**：`contactClaimed` 恒 false，没有真实渠道。
- **后台导航不支持**：需要保持屏幕亮、App 在前台。
- **ultralytics_yolo 是 AGPL-3.0**：仅为比赛演示保留，赛后需迁移。

---

## 四、当前交付状态

- 分支 `fix/whole-test-4-frontend`（HEAD 以 `git log -1` 为准，已推送 origin）。
- 全量串行回归：**1068 项全绿**（`--concurrency=1`，约 4 分钟）；`dart analyze lib test` 无告警。
- arm64 演示包：由 `tool/build_release_apk.sh` 产出，仅 `arm64-v8a`，含 `yolo11n.tflite`，
  **debug 签名**（沿用 `build.gradle.kts` 现有约定，仅供演示，上架需换正式 keystore）。
- **当前包未注入路线配置**，导航/路线演示不可用，APK 旁会生成 `*.NOTICE.txt` 提示；
  正式演示需先填 `tool/release_defines.local.env` 再用 `--require-routes` 构建。
