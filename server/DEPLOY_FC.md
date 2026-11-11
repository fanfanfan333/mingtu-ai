# 把云端识图部署到阿里云函数计算（FC）

本文把 `server/` 里的识图代理部署为阿里云函数计算（Function Compute，FC）的 HTTP 触发器函数。部署完成后，App 只把单帧图片发到这个函数的 HTTPS 地址；百炼（DashScope）密钥只存在于函数的环境变量里，**不进 APK、不进仓库、不进日志**。

步骤来源：阿里云官方文档（链接见文末）。官方文档没有核对到的控制台细节，本文明确标注为 **待核对**，请以你打开控制台时看到的实际界面为准，不要凭本文猜菜单。

## 0. 部署物（先看这一节）

- **代码目录**：`server/fc/`，自包含，只含两个文件：
  - `index.py`：入口，只做一件事——把 `amap_proxy.py` 的 `handler` 暴露出来。
  - `amap_proxy.py`：识图处理本体（令牌校验、限流、结构化输出）。
- **入口函数名（请求处理程序 Handler）**：`index.handler`。官方文档说明：对 Python 函数，请求处理程序格式为“文件名.方法名”，可通过函数计算控制台的**请求处理程序**配置（见文末链接 1）。
- **运行时**：函数计算内置运行时 Python 3.10（推荐，依据见 §2 第 2 条）。
- **依赖**：只使用 Python 标准库，**没有第三方依赖**，不需要 requirements.txt、不需要装包。
- **打包**：在 `server/fc/` 目录运行 `./build_zip.sh`，生成 `mingtu-fc.zip`（只含上述两个 .py 文件，位于 zip 根目录；脚本保证不含 .env、不含任何密钥）。也可以直接把 `server/fc/` 目录里的两个文件打包成 zip，效果相同。
- **环境变量**：`MINGTU_DASHSCOPE_API_KEY`（必填）、`MINGTU_VISION_TOKEN`（必填）等，见第 4 节。
- **客户端构建只需两个 --dart-define**：`MINGTU_VISION_PROXY_URL`（本函数的 https 地址）和 `MINGTU_VISION_TOKEN`（演示令牌），确切名字与示例命令见第 7 节。

## 1. 开通函数计算

- 在阿里云控制台开通函数计算 FC。开通入口、是否需要实名/绑卡等前置条件：**待核对**（以 [函数计算文档首页](https://help.aliyun.com/zh/functioncompute/) 的“快速入门/开通”说明为准）。
- 地域建议选离使用者近的地域（例如华东/华北）；具体地域列表与选型：**待核对**。

## 2. 创建函数

官方文档中可核对的导航路径是：登录函数计算控制台后，左侧导航栏选择 **函数管理 > 函数列表**，在顶部菜单栏选择地域（见文末链接 2 的操作步骤）。

1. 在函数列表页创建新函数。创建向导里的函数类型、创建方式等字段名称与选项：**待核对**（不同版本控制台叫法不同；目标是创建一个“事件函数”，运行时选 Python 3）。
2. 运行时选 **Python 3.10**（本代码只依赖 Python 标准库，不需要装任何第三方包）。官方文档列出的内置 Python 运行时：Python 3.12（标识符 python3.12，官方页标注公测中）、Python 3.10（python3.10）、Python 3.9（python3.9）、Python 3.6（python3），见 [Python 运行时](https://help.aliyun.com/zh/functioncompute/fc/python/)。控制台创建页的实际可选列表如与文档不一致，以控制台为准（**待核对**）。
3. 在函数的**请求处理程序**配置里填 `index.handler`。

## 3. 上传代码

官方文档可核对的路径：在函数详情页面单击**代码**页签，在代码编辑器中编写代码，然后单击**部署代码**（见文末链接 2）。

1. 先在本机生成部署包：在 `server/fc/` 目录运行 `./build_zip.sh`，得到 `mingtu-fc.zip`。
2. 把 `mingtu-fc.zip` 作为代码包上传（控制台的代码包/zip 上传方式的当前菜单名：**待核对**）；也可以用在线编辑器分别粘贴 `index.py` 与 `amap_proxy.py` 两个文件的内容。
3. 单击**部署代码**，等部署完成。

## 4. 设置环境变量

函数运行时需要以下环境变量（在函数的环境变量配置处设置；控制台里环境变量配置页签的确切名称与位置：**待核对**，一般在函数的“配置”相关页面）：

| 变量 | 必填 | 说明 |
|---|---|---|
| `MINGTU_DASHSCOPE_API_KEY` | 是 | 百炼（DashScope）密钥。只填在这里，绝不出现在 App、仓库或日志中。未设置时 `/vision` 返回 503，App 播报降级。 |
| `MINGTU_VISION_TOKEN` | 是 | 演示令牌。自己生成一串足够长的随机字符串填这里，并用同一个值构建 App（见第 7 节）。未设置时函数对所有识图请求一律拒绝（503，失败关闭）。演示结束后更换或删除此值即可作废旧 App 的调用权。 |
| `MINGTU_VISION_PER_MINUTE` | 否 | 每分钟调用上限，默认 10。 |
| `MINGTU_VISION_PER_DAY` | 否 | 每天调用上限，默认 100。 |
| `MINGTU_ASR_PER_MINUTE` | 否 | `/asr`（云端语音识别兜底）每分钟调用上限，默认 10。与识图限流相互独立。 |
| `MINGTU_ASR_PER_DAY` | 否 | `/asr` 每天调用上限，默认 60。与识图限流相互独立。 |

注意：限流计数是**每个函数实例内存内**的（FC 会弹性伸缩出多个实例），它是防滥用刹车，不是精确计费配额；真正的费用护栏还有百炼侧的额度与本函数的输出上限（服务端强制 `max_tokens ≤ 256`、关闭思考模式）。

## 5. 创建 HTTP 触发器并获取 HTTPS 地址

官方文档可核对的步骤（见文末链接 2）：

1. 在函数详情页面，单击**触发器**页签，然后单击**创建触发器**。
2. 在创建触发器面板里，**触发器类型**选择 **HTTP 触发器**；**请求方法**至少包含 `POST`（本函数只处理 POST 到 `/vision` 路径；其余路径返回 404）。
3. **认证方式**选择**无需认证**。官方文档列出的认证方式包含无需认证、签名认证、JWT 认证、Bearer 认证等（见文末链接 1 的说明）：App 端无法做 FC 的签名认证，所以这里选无需认证，改由我们自己的演示令牌（第 4 节）在函数内部校验。不要因为“无需认证”就省略令牌——没有令牌，任何人都能消耗你的百炼额度。
4. 单击**确定**完成创建。

获取地址：在函数详情页面的**触发器**页签，可以获取 HTTP 触发器的**公网访问地址**（形如 `https://<...>.fcapp.run`，见文末链接 1 的示例）。这个地址就是第 7 节要填给 App 的代理地址，**必须是 https**（App 会拒绝 http 地址）。

触发器与函数 URL 的关系、自定义域名等进阶话题见官方《HTTP 触发器概述》（文末链接 3）：**待核对**，演示阶段用触发器公网地址即可。

## 6. 用 curl 自测

把下面的 `<FC地址>` 换成第 5 节拿到的公网访问地址，`<演示令牌>` 换成第 4 节设置的值。示例里的图片是占位假数据（`AAAA`），不会产生真实识图结果；自测重点是看守卫链是否工作。

1）不带令牌 → 应返回 401 和结构化错误：

```bash
curl -i -X POST "<FC地址>/vision" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.7-flash","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},{"type":"text","text":"test"}]}],"max_tokens":256,"enable_thinking":false}'
# 期望：HTTP 401，响应体 {"error": "unauthorized"}
```

2）令牌错误 → 同样 401。把请求头换成 `-H "X-Mingtu-Vision-Token: wrong"` 重复上面的请求即可验证。

3）令牌正确 → 通过守卫，进入识图流水线：

```bash
curl -i -X POST "<FC地址>/vision" \
  -H "Content-Type: application/json" \
  -H "X-Mingtu-Vision-Token: <演示令牌>" \
  -d '{"model":"qwen3.7-flash","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},{"type":"text","text":"test"}]}],"max_tokens":256,"enable_thinking":false}'
# 期望：不再是 401；若百炼密钥已配置且占位图片被上游接受处理，
# 返回结构化 JSON（scene/obstacles/parsed）；占位假图也可能得到
# 502 upstream failure 或 parsed:false 的“识别不确定”——都说明
# 守卫链已通过、请求已到达流水线。用真实 App 拍一帧再验成功路径。
```

4）连续快速调用超过每分钟上限 → 返回 429 `{"error": "rate_limited"}`。

任何响应里都不应出现百炼密钥或令牌的值；如果出现，立即停用并检查代码版本。

## 7. 构建带识图的 App

```bash
flutter build apk --debug \
  --dart-define=MINGTU_VISION_PROXY_URL=<FC地址> \
  --dart-define=MINGTU_VISION_TOKEN=<演示令牌>
```

## 7c. `/asr` 路由：云端语音识别兜底（2026-11-10 新增）

为什么有这一条：小米 15（HyperOS）真机上，系统语音识别服务是小米自己的语音引擎，该引擎自身没有麦克风权限时系统识别直接报 `error_permission`，按住说话完全不可用。因此 App 增加兜底：按住时改用 App 自己的麦克风权限录音（16 kHz 单声道 WAV、最长 10 秒），松手后把录音发到本函数的 `/asr` 路由转写，转写文本走原有语音指令流程。

- 模型选型（服务端写死，客户端传什么模型都会被拒绝/忽略）：**`qwen3-asr-flash`**，百炼北京地域，OpenAI 兼容同步接口，音频以 base64 data-URI 直传。价格 0.00022 元/秒，免费额度 36000 秒/90 天。选它是因为在“同步调用 + base64 直传”两个约束下它是可用档里最便宜的；`paraformer-v2` 单价更低（0.00008 元/秒），但只有异步 API 且只接受公网 URL、不接受 base64，不适合按住说话的短录音，故不用。
- 守卫与 `/vision` 相同：同一个演示令牌请求头（`X-Mingtu-Vision-Token`）；但限流是**独立**的一套（上表 `MINGTU_ASR_*`），识图额度用满不影响语音识别，反之亦然。请求体上限 1 MB，解码后音频上限 400 KB。百炼密钥仍只从 `MINGTU_DASHSCOPE_API_KEY` 读，未配置时 `/asr` 返回 503 `asr_not_configured`，App 播报固定降级文案。
- 部署动作：本路由随函数代码一起发布——**需要重新打包 `server/fc/build_zip.sh` 并重新上传 zip**（或在控制台更新代码），旧版本函数没有 `/asr`。
- App 构建参数：可选 `--dart-define=MINGTU_ASR_PROXY_URL=<FC地址>`；不填时 App 自动回落使用 `MINGTU_VISION_PROXY_URL` 的地址（同一函数部署、同一令牌）。
- 诚实状态：**FC 未重新部署前，兜底不可用**（App 会播报“云端识别未配置/暂时不可用”）；本路由只经过 fixture/mock 测试，**未经真机验证，也未做过真实百炼调用**。
- WAV 头校验（MT-1111-PTT-2，2026-11-11）：服务端手工解析 RIFF 头，只接受 PCM、16 bit、单声道、采样率 8000–48000 的 WAV，时长（按 data 块字节数计算）不得超过 10.5 秒；不合规返回 400（`audio format not allowed` / `audio too long`）。**校验在限流扣减之前**：校验失败不调用上游、也不消耗 `/asr` 限流额度；令牌校验仍在最前且不消耗额度。


- 地址必须是第 5 节的 https 地址；填 http 会被客户端拒绝并播报“识图未配置”。
- 不带这两个参数构建的 App 会播报“识图未配置”并降级为本地检测，这是预期行为。
- 令牌会编进 APK 且可被提取：它只是演示期的防滥用令牌，不是密钥。**演示结束后**，在 FC 环境变量里更换或删除 `MINGTU_VISION_TOKEN`，旧 App 立即失效。
- 百炼密钥永远只在第 4 节的 FC 环境变量里，不要尝试用 `--dart-define` 把它打进 App——客户端已经没有任何百炼密钥的注入点（有自动化测试守着这一点）。

## 7b. 限流的诚实边界：把实例数设为 1，并在百炼侧设限流（必读）

本函数的识图限流计数保存在**单个实例的进程内存**里。多实例部署时每个实例各算各的，总放行量会随实例数放大，所以它只是滥用刹车，不是配额系统。部署时两个闸门都要补上：

1. **把函数的最大实例数设为 1**（演示期）：这样进程内限流就是全局限流。控制台中该设置项的确切位置与名称：**待核对**（请查阅 [函数计算文档](https://help.aliyun.com/zh/functioncompute/) 的伸缩/实例配置章节后在控制台核对）。
2. **在百炼侧给模型设限流**：百炼按主账号维度对模型调用限流，并可按业务空间设置请求数（QPM）与 Token 用量（TPM）上限——给 `qwen3.7-flash` 设一个低限额，超限由百炼直接拒绝。官方说明：[百炼限流](https://docs.bailian.console.aliyun.com/zh/model-studio/rate-limit)、[更新模型限流](https://help.aliyun.com/zh/model-studio/update-model-rate-limits)。
3. 另外建议开启百炼/费用中心的用量告警（入口与设置方式：**待核对**），避免演示令牌泄露时费用失控增长。

## 8. 费用

本文不估算费用数字。函数计算的计费方式与最新价格只看官方页面：

- 计费概述（官方）：https://www.alibabacloud.com/help/zh/functioncompute/billing-overview-of-fc
- 定价页（官方）：https://www.alibabacloud.com/zh/product/function-compute/pricing

另外，百炼 `qwen3.7-flash` 的调用费用发生在百炼侧，与 FC 费用分开计，请在百炼控制台看它自己的计费与额度（其官方定价不在本文范围内，**待核对**）。

## 官方文档链接

1. Python 请求处理程序（Handler）与 HTTP 触发器调用示例：https://help.aliyun.com/zh/functioncompute/event-handlers-1-1
2. 配置 HTTP 触发器：https://help.aliyun.com/zh/functioncompute/configure-an-http-trigger-for-a-function-and-invoke-the-function-by-using-http-requests
3. HTTP 触发器概述：https://help.aliyun.com/zh/functioncompute/http-triggers-overview
4. HTTP 触发器调用函数（事件结构、请求体 Base64 规则）：https://help.aliyun.com/zh/functioncompute/http-trigger-invoking-function
5. 函数计算文档首页：https://help.aliyun.com/zh/functioncompute/
