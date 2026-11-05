# 明途百炼接入说明（不发 Key 给 Muse）

## 关键区分

- 学生券 / 额度是**账号级**的，挂在你的阿里云百炼账号上，不是一串可以发给别人的东西。
- API Key 只是证明“这是你的账号”的凭证。Key 永远只在你自己的电脑 / 手机上，不发给 Muse、不写进代码、不提交到 GitHub、不出现在截图和提交材料里。

## 在百炼控制台做（你自己操作）

1. 确认学生券 / 余额已到账。
2. 新建一个 DashScope API Key，自己保管。
3. 在模型列表里确认你要用的模型 ID 原样是什么（代码默认 `qwen3-vl-flash`，以控制台为准，不要凭记忆改）。

## 在你电脑上跑（Key 只在这里出现）

```sh
flutter run \
  --dart-define=MINGTU_LLM_MODEL_ID=qwen3-vl-flash \
  --dart-define=MINGTU_DASHSCOPE_API_KEY=你的Key只写在这里
```

不要把上面这条带真实 Key 的命令截图发出来，也不要把它存进仓库文件。

## 代码里是怎么管住的

- `lib/config/app_config.dart`：Key 只从 `--dart-define` 读，界面只显示“已配置 / NOT_CONFIGURED”，永不显示值。
- `lib/adapters/bailian_client.dart`：DashScope OpenAI 兼容接口
  `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`。
  只有先拿到 `LlmGateway` 的允许决策（本地先试过且不够用、预算内）才发请求；
  没 Key、网关拒绝、预算不足时一律不发网络请求。
  报错时 Key 会被替换成 `[REDACTED]`，不会原样返回。
- 演示界面有两个分开的按钮：
  - “云端网关演示”只返回决策，永不产生费用；
  - “百炼真实调用”只有你主动点按、且本机已配置 Key 时才真正调用一次，点一次花一次（按百炼实际计费）。

## 还没验证的

- 真实百炼调用、真实计费、真实模型返回质量：只能在你本机带 Key 跑一次后才算验证，云端测试用的是假发送器，不产生费用也不证明百炼已通。
- 视觉调用（传一帧图）还没做：现在客户端只发文本提示，连续视频绝不上传云端。
