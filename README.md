# Lamp

Lamp 是一个原生 SwiftUI iPhone 个人规划 Agent。它的核心不是聊天，而是持续回答：**我现在应该做什么？**

当前仓库包含一个可直接运行的产品原型、确定性排程核心、Live Activity / Dynamic Island 扩展、App Shortcuts，以及已接通的 Supabase + DeepSeek 安全图片日程链路。

## 已实现

- 三步低摩擦 onboarding。
- Now + Today 主界面与固定/灵活/休息时间线。
- 完成、部分完成、未完成反馈和剩余时长更新。
- Today / Week / Roadmap 三个规划尺度。
- 四个主页面上方统一显示琥珀色玻璃“和 Lamp 对话”入口。
- Tell Lamp：文字、中文语音转写、DeepSeek Vision 图片日程理解与本机 OCR 降级预览。
- 图片候选可编辑、筛选并检查冲突，确认后一次性导入 Today / Week，整次操作可撤销。
- 每周重复日程、稳定 occurrence ID 与只影响单次的完成、跳过、改期 override。
- “今天很累”临时状态与可预览、确认的轻量重排。
- “Lamp 了解的你”：可查看、删除的记忆与可开关规则。
- 本地 JSON 离线持久化与演示数据。
- Live Activity / Dynamic Island 的倒计时、完成和部分完成控制。
- “打开今天”“告诉 Lamp”App Shortcuts。
- 混合排程引擎与 16 个确定性核心测试。
- Supabase 匿名认证、Postgres/RLS 数据模型和 DeepSeek 工具白名单、风险分类、幂等审计边界。

## 运行

要求：Xcode 26.6 或兼容版本，iOS 18+。

1. 打开 `Lamp.xcodeproj`。
2. 选择 `Lamp` scheme 和任意 iPhone 模拟器。
3. Run。

命令行验证：

```bash
xcodebuild -project Lamp.xcodeproj -scheme Lamp -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
swift test
```

## 云端配置

原型默认使用本地离线数据，不包含任何私钥。要启用云端：

1. 创建 Supabase 项目并执行 `supabase db push`。
2. 在 Auth 设置中开启匿名登录。
3. 部署 `supabase/functions/agent` 与 `supabase/functions/image-schedule`。
4. 仅在服务端配置 `DEEPSEEK_API_KEY`、`DEEPSEEK_MODEL`、`DEEPSEEK_VISION_MODEL` 和 `DEEPSEEK_BASE_URL`。
5. iOS 端只使用可公开的 Supabase publishable key；匿名 session 安全保存在 Keychain。

DeepSeek 永远不获得数据库连接。图片会在本机统一方向、缩放、压缩并临时发送，不写入 Storage；服务端只审计用户、模型、图片哈希、候选数量、耗时和结果状态。

## 本机 DeepSeek 联调

当前开发机的 DeepSeek Key 已保存在 macOS Keychain 的 `com.lamp.deepseek` 条目中，不会进入仓库或 App 二进制。启动安全开发代理：

```bash
node server/local-agent-proxy.mjs
```

Debug 版 App 会调用 `http://127.0.0.1:8787/v1/interpret`。代理只绑定本机回环地址、从 Keychain 读取凭证，并只接受 `create_item`、`set_temporary_state`、`ask_clarification` 三种白名单模型输出。代理未启动或调用失败时，App 自动使用离线规则。

## 仍需真机/生产环境完成

- 锁屏直接录音必须按 `docs/architecture/0005-lock-screen-voice.md` 在真机逐项验证；当前可靠路径是部分完成后一步打开最小录音界面。
- 完整计划云同步与正式账户升级仍是后续工作；当前 Supabase 只负责匿名认证、AI 安全代理和最小审计。
- DeepSeek 视觉模型仍为实验模型，保留服务端环境变量切换和 Apple Vision 只读降级路径。
- HealthKit 保留为可选后续集成，不参与医疗判断。

架构决策见 `docs/architecture/`。
