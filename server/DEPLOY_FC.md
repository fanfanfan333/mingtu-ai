# 把云端识图部署到阿里云函数计算（FC）

本文把 `server/` 里的识图代理部署为阿里云函数计算（Function Compute，FC）的 HTTP 触发器函数。部署完成后，App 只把单帧图片发到这个函数的 HTTPS 地址；百炼（DashScope）密钥只存在于函数的环境变量里，**不进 APK、不进仓库、不进日志**。

步骤来源：阿里云官方文档（链接见文末）。官方文档没有核对到的控制台细节，本文明确标注为 **待核对**，请以你打开控制台时看到的实际界面为准，不要凭本文猜菜单。

## 0. 部署物

上传到函数的代码共两个文件（都在 `server/` 目录）：

- `index.py`：入口，只做一件事——把 `amap_proxy.py` 的 `handler` 暴露出来。
- `amap_proxy.py`：识图处理本体（令牌校验、限流、结构化输出）。

函数的**请求处理程序（Handler）配置为 `index.handler`**。官方文档说明：对 Python 函数，请求处理程序格式为“文件名.方法名”，可通过函数计算控制台的**请求处理程序**配置（见文末链接 1）。

## 1. 开通函数计算

- 在阿里云控制台开通函数计算 FC。开通入口、是否需要实名/绑卡等前置条件：**待核对**（以 [函数计算文档首页](https://help.aliyun.com/zh/functioncompute/) 的“快速入门/开通”说明为准）。
- 地域建议选离使用者近的地域（例如华东/华北）；具体地域列表与选型：**待核对**。

## 2. 创建函数

官方文档中可核对的导航路径是：登录函数计算控制台后，左侧导航栏选择 **函数管理 > 函数列表**，在顶部菜单栏选择地域（见文末链接 2 的操作步骤）。

1. 在函数列表页创建新函数。创建向导里的函数类型、创建方式等字段名称与选项：**待核对**（不同版本控制台叫法不同；目标是创建一个“事件函数”，运行时选 Python 3）。
2. 运行时版本选 Python 3 系列（本代码只依赖 Python 标准库，不需要装任何第三方包）。具体可选版本号：**待核对**。
3. 在函数的**请求处理程序**配置里填 `index.handler`。

## 3. 上传代码

官方文档可核对的路径：在函数详情页面单击**代码**页签，在代码编辑器中编写代码，然后单击**部署代码**（见文末链接 2）。

1. 把 `index.py` 和 `amap_proxy.py` 两个文件的内容放到函数代码里（在线编辑器粘贴，或用控制台提供的代码包上传方式上传一个只包含这两个文件的 zip；上传方式的当前菜单名：**待核对**）。
2. 单击**部署代码**，等部署完成。

## 4. 设置环境变量

函数运行时需要以下环境变量（在函数的环境变量配置处设置；控制台里环境变量配置页签的确切名称与位置：**待核对**，一般在函数的“配置”相关页面）：

| 变量 | 必填 | 说明 |
|---|---|---|
| `MINGTU_DASHSCOPE_API_KEY` | 是 | 百炼（DashScope）密钥。只填在这里，绝不出现在 App、仓库或日志中。未设置时 `/vision` 返回 503，App 播报降级。 |
| `MINGTU_VISION_TOKEN` | 是 | 演示令牌。自己生成一串足够长的随机字符串填这里，并用同一个值构建 App（见第 7 节）。未设置时函数对所有识图请求一律拒绝（503，失败关闭）。演示结束后更换或删除此值即可作废旧 App 的调用权。 |
| `MINGTU_VISION_PER_MINUTE` | 否 | 每分钟调用上限，默认 10。 |
| `MINGTU_VISION_PER_DAY` | 否 | 每天调用上限，默认 100。 |

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

- 地址必须是第 5 节的 https 地址；填 http 会被客户端拒绝并播报“识图未配置”。
- 不带这两个参数构建的 App 会播报“识图未配置”并降级为本地检测，这是预期行为。
- 令牌会编进 APK 且可被提取：它只是演示期的防滥用令牌，不是密钥。**演示结束后**，在 FC 环境变量里更换或删除 `MINGTU_VISION_TOKEN`，旧 App 立即失效。
- 百炼密钥永远只在第 4 节的 FC 环境变量里，不要尝试用 `--dart-define` 把它打进 App——客户端已经没有任何百炼密钥的注入点（有自动化测试守着这一点）。

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
