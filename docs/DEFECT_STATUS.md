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

## 一之二、语音口令解析批次（2026-11-16 晚，D1–D8 + N1–N6）

这一批全部集中在 `lib/core/voice_commands.dart`（纯 Dart，无 Flutter 依赖）+ `lib/main.dart` 一处播报。
之所以单独成节：它不是「功能缺失」，而是**口令被解析成相反动作**——对盲人来说等于按错按钮。

### 8. 四类「反向动作 / 漏识别」（P0 安全）

| 编号 | 现象（修复前实测） | 应为 | 危害 |
|---|---|---|---|
| D1 | `停` / `停。` / `停！` / `站住` / `别动` / `停住` / `停一停` → `unknown` | pause | 遇险喊「停」，App 回「没听清」 |
| D2 | `别继续了` / `不继续了` / `不要继续走了` → `resume` | pause | 要停，App 反而恢复导航并继续播报 |
| D3 | `别删除录像` → `deleteRecording` | saveRecording | 想留证据，录像被真删 |
| D4 | `我不去图书馆了` / `别去图书馆` → `startLibrary` | cancel | 说「不去」，App 开始带他走 |

**共同根因**：`parseVoiceCommand` 是「正向关键字优先」的长 `if` 链——
(a) 归一化只去掉了 `小途` 和两个逗号，ASR 常带的句号/感叹号原样保留，单字口令永远匹配不上；
(b) 动作分支前面没有否定判断，`contains('继续')` 先于任何否定，
(c) 否定词表只覆盖连续子串（`不去了`），被目的地/副词隔开就失效。

**修复**：
- 统一归一化 `_ignorableChars`（中英文标点、引号、括号、空白）→ 单字口令可精确匹配。
- D1：`text == '停'` + `^停+$`（`停停停`）+ 复合词，**不使用裸 `contains('停')`**（否则「我要停车」会被误判）。
- D2/N1：`_isNegatedContinue` 在 `resume` 之前；裸「不」只在紧邻「继续/恢复」时算，另收 `别/不要/不用/不想/不必/不需/没必要/甭/莫`。
- D3/N3：`_isNegatedDelete` 提到急停分支之前；「别动我的录像」走相邻正则 `_negatedRecordingTouch`，避免把「别碰我，我在录像」当成数据请求。
- D4：`_isNegatedDestination`（否定 + 目的地）→ cancel；`_isDestinationQuestion`（在哪/多远/什么地方…）→ unknown；**正向分支保持原样**，
  单说「图书馆」与「图书馆怎么走」仍是 `startLibrary`（曾被工程师收窄成「必须带移动动词」，已打回）。
- 问句/命令区分：`_looksLikeQuestion` 只认 `吗/什么/怎么/为什么/有没有/是不是/在哪`；复合急停词遇问句让路，
  但**句首就是命令**时不让（`站住，有人吗` → pause）。

**证据**（可复跑）：
- 44 条断言探针（主理人自建，覆盖 D1–D8 全部正/反锚点）：**0 条不符合**。
- 单测：`test/voice_commands_test.dart` 9 个用例、约 60 条断言，含每个缺陷的**反向锚点**
  （`我要停车`→unknown、`停车场在哪`→不得 pause、`图书馆`→startLibrary、`继续`→resume…）。
- 反向验证（改坏必红，逐字恢复后复绿）：D1 去掉急停分支、D2 去掉否定守卫、D3 去掉否定删除、
  D4 去掉否定目的地、D6 去掉问句门、D7 挪回原位置、N1 删 `不需`、N2 加回裸 `么`、N3 换回裸词、
  N4 去掉句首豁免、N6 注释 `停一停`——**每一项都确认了具体哪条断言变红**，不是"感觉修好了"。

### 9. 本轮自己引入又被打回的 6 处（诚实记录，供后续复查）

这一批不是一次写对的。第二轮 QA 判过 **NO-SHIP**，理由成立：

| 编号 | 修复中引入的问题 | 触发说法 | 处理 |
|---|---|---|---|
| D6→N2 | 问句豁免把裸 `么` 当问句标记 | `这么多台阶，站住` → unknown | 删裸 `么`，改 `什么/怎么/为什么` |
| D6→N4 | 命令 + 顺口一问被整条豁免 | `站住，有人吗` → unknown | 加句首命令豁免 |
| D7→N3 | 「别动/别碰」裸词抢走急停 | `别碰我，我在录像` → saveRecording（谎报"已保存"） | 改相邻正则 |
| D8→N1 | 收窄裸「不」后漏掉 `不必/不需要/没必要` | `不需要恢复导航` → resume | 补词；`不需` 覆盖"不需要" |
| D5 | idle 态撤回播报是演示腔「请先重置演示」 | 盲人无法执行 | 按状态分档（见第 10 条） |
| 收窄正向分支 | 为了让问路句落 unknown，把 `startLibrary` 改成「必须带移动动词」 | `图书馆` / `图书馆怎么走` → unknown | **打回**，改为独立的问句守卫 |

教训：**过匹配（多停一次）和漏识别（该停没停）不对称**。修过匹配时若用「收紧关键字」的粗办法，
很容易把 P0 的漏识别换回来；每次收紧都必须同时钉住"原来的锚点不许被打死"。

### 10. idle 态撤回意图的播报（D5）

- 现象：`TaskState.idle` 的合法出边只有 `listening`/`emergency`，`canTransitionTo(cancelled)` 为 false，
  于是用户随口说「我不去图书馆了」会听到「当前状态不能取消，**请先重置演示**」——真实盲人手里没有"演示"可重置。
- 修复：新增 `lib/core/voice_replies.dart` 的 `cancelRejectedSpeech(TaskState)`，三档：
  idle →「好的，不去了。需要导航时随时说“去图书馆”。」；终态 →「任务已经结束，不用再取消。」；其余 →「当前状态不能取消。」
- 证据：`test/voice_cancel_reply_test.dart`（纯 Dart，3 条）+ `test/voice_cancel_idle_reply_test.dart`
  （widget，用录制型 fake TTS 抓真实播报时间线，断言出现「好的，不去了」且**不出现**「重置演示」）。

### 11. 环境：`flutter test` 报 `Invalid WebSocket upgrade request`

- 现象：任意 `flutter test` 在 loading 阶段失败，`Unable to connect to flutter_tester process`；
  同一台机器 `dart test`（纯 VM）正常。
- 根因：代理拦截了 localhost 的 WebSocket upgrade。**与代码无关**，但会把「环境故障」误读成「测试坏了」。
- 处理：跑测试前清代理并放行本地回环：
  `NO_PROXY=localhost,127.0.0.1 HTTP_PROXY= HTTPS_PROXY= … flutter test`。
  另：本项目路径含中文，`flutter analyze` 会让 analysis_server 在 LSP 字节通道上崩
  （`FormatException: Unexpected end of input`），**用 `dart analyze lib test` 才可靠**。

### 12. 打包脚本自己把 NOTICE 告警吃掉了（构建期，B1）

- 现象：`bash tool/build_release_apk.sh` 已经把包装出来了（22.4MB、SHA 都打印了），
  但**退出码是 1**，而且第 8 步「缺路线配置时写 `*.NOTICE.txt`」根本没执行。
- 根因：脚本 `set -euo pipefail` 下，第 460 行 `rm -f "$DEFINES_MANIFEST" "$VERIFY_SCRIPT"`
  要删的是 `mktemp` 产生的 `D:/Temp/tmp.XXX`；本机宿主对 `rm` 有 safe-delete 包装，
  它把这个 Windows 绝对路径当**相对路径**解析成 `d:\明途AI\mingtu-ai\D:\Temp\tmp.XXX`，
  trash 失败 → fail-closed → `rm` 非 0 → `set -e` 当场结束脚本。
- 危害：比"退出码不好看"严重得多——**NOTICE 的存在意义就是防止「没注入路线配置的包被误发」，
  而它恰好被这一步跳过了**，告警机制在最需要的时候失效。
- 修复：`cleanup()` 与第 460 行的 `rm` 都改成失败不致命（`2>/dev/null || true`），
  并补注释说明宿主 safe-delete 的这个行为。
- 证据：修前 `EXIT=1` 且无 NOTICE（已实测）；修后 `EXIT=0`、`==> 完成`、`app-release.apk.NOTICE.txt`
  正常生成（内容首行「此 APK 缺少路线配置，不能作为导航/路线演示包。」），构建日志里不再有 safe-delete 报错。
  补充说明：曾尝试用嵌套 `bash -c` 做最小反证，但宿主的 safe-delete 只包装顶层工具命令，
  嵌套里复现不了，因此本条的证据是**完整构建的 before/after**，不是最小探针。

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

### 语音口令的已知边界（本轮实测取值，刻意不改，如实记录）

这些不是"还没发现"，是**测过、判过、暂时接受**的：

| 说法 | 当前取值 | 为什么不改 |
|---|---|---|
| `能停住吗` / `可以停住吗` | unknown | 语义两可（请求 App 停 / 自问能不能停），判 pause 会因问句误停；判 unknown 至少不做错动作 |
| `停不住` | unknown | 是求助（"我停不住"），目前没有对应动作；给不出可靠回应就不假装听懂 |
| `继续吗` / `恢复吗` | resume | 征询被当命令，方向是"多继续"，可自愈（再说「停」即可） |
| `不要碰我` | unknown | 与 `别碰我`→pause 不对称（`别碰` 有归属、`不要碰` 没有）；修它要动分支顺序，留待下轮 |
| `不要录像` | deleteRecording | 语义上"不要录像=删"成立，与"别删除录像=保留"不矛盾 |
| `别录像` | unknown | 没有"关闭录像"这条命令 |
| `？` / `?` | 被归一化剥掉 | 问号承载的疑问语义丢失，`停住？` 与 `停住` 不可区分；急停宁可多停 |
| 目的地 | 硬编码「图书馆」 | `_isNegatedDestination` / `_isDestinationQuestion` / 正向分支三处各自写死；新增目的地时必须三处同步，否则 D4 类反转会逐字复发 |

---

## 四、当前交付状态

- 分支 `fix/whole-test-4-frontend`（HEAD 以 `git log -1` 为准，已推送 origin）。
- 全量串行回归：**1081 项全绿**（`--concurrency=1`，约 5 分钟）；`dart analyze lib test` 无告警。
  （计数说明：本轮把 `停一停` 等断言加进了既有表驱动 `test()` 的循环里，`dart test` 数的是用例体，
  所以总数仍是 1081；断言条数增加但用例体个数不变。）
- arm64 演示包：由 `tool/build_release_apk.sh` 产出，仅 `arm64-v8a`，含 `yolo11n.tflite`，
  **debug 签名**（沿用 `build.gradle.kts` 现有约定，仅供演示，上架需换正式 keystore）。
- **当前包未注入路线配置**，导航/路线演示不可用，APK 旁会生成 `*.NOTICE.txt` 提示；
  正式演示需先填 `tool/release_defines.local.env` 再用 `--require-routes` 构建。
- 本轮重建产物：`D:\明途AI\deliverables\mingtu-arm64-s4-20261116.apk`
  （22.4 MB，SHA256 `a074ab44…31289`，构建脚本退出码 0，NOTICE 同目录），
  内含本次语音口令修复与 `cancelRejectedSpeech` 播报分档。
