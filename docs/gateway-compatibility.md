# 网关兼容要求 / Gateway compatibility

MOS 是 Hermes 网关客户端，不是通用 LLM API 客户端。本表来自本仓库实现，描述所使用的协议；它不是服务端兼容性测试报告。

接口开发基线为 Hermes 0.22.4。不同安装方式、认证设置、插件及后续版本可能有差异；目前没有逐版本的通过清单。请先确认所部署版本提供下面的能力，再尝试真实任务。

## 核心连接

| 能力 | 客户端依赖 | 实现位置 |
| --- | --- | --- |
| 状态 | `GET /api/status` | `GatewayTransport.swift` / `ChatStore.swift` |
| 原生认证 | `GET /auth/native/authorize`、`POST /auth/password-login`、`POST /auth/native/token`、`POST /auth/native/refresh`；basic provider、PKCE S256 与 state 校验 | `GatewayTransport.swift` |
| 当前用户 | `/api/auth/me` | `ChatStore.swift` |
| 实时连接 | `POST /api/auth/ws-ticket`，随后 `/api/ws` WebSocket；JSON-RPC 2.0 | `GatewayTransport.swift` |
| 连接协商 | ready 帧、`client.capabilities`、`ping` | `GatewayTransport.swift` |
| Bot 身份 | `profiles.list`，包含 canonical session；必要时 `session.list` 查询固定 Bot Chat | `ChatStore.swift` |
| 会话绑定与历史 | canonical Bot Chat 标识、运行时 session 标识；`session.resume`、`/api/sessions/{id}/messages` 与会话事件 | `ChatStore.swift` |

原生登录目前使用用户名密码／basic provider 流程。仅有 OAuth 网页登录、API key 或其他认证 provider 的网关，不能假设可直接连接。

## 按能力提供的功能

| 功能 | 需要的服务端能力 | 实现位置 |
| --- | --- | --- |
| 聊天、停止、审批、补充问题 | 会话消息／事件 RPC、停止请求、server requests 与原始选项 | `ChatStore.swift` / `GatewayTransport.swift` |
| 会话模型 | `model.options`；带 revision/generation 的 `session.mutate`，或旧式 session-scoped `config.set` | `ChatStore.swift` |
| 命令 | `commands.catalog`、`slash.exec`，必要时 `command.dispatch` | `SlashCommands.swift` |
| 附件与结果文件 | 上传、会话附件以及文件下载 HTTP API | `GatewayTransport.swift` |
| 定时任务 | profile-scoped cron API 与远端调度 | `BotWorkspace.swift` |
| 共享看板 | Hermes Kanban REST API、board 标识与远端调度器 | `BotWorkspace.swift` |
| profile／工具／Skills／MCP | 对应目录、读取与写入接口，目标 profile 路由 | `ProfileConfiguration.swift` |
| 默认／辅助／备用模型 | 远端模型目录与 profile 模型配置 API | `ProfileModelConfiguration.swift` |
| 消息平台与扫码 | `/api/messaging/platforms` 目录／配置，以及对应 onboarding API | `ProfileMessagingConfiguration.swift` |

这里的“提供”表示客户端已有相关界面与代码。操作是否成功由远端的接口、权限、模型和插件决定；例如 Telegram／WhatsApp 扫码依赖网关提供对应流程，不代表 MOS 内置了独立消息桥。

MOS 对每个 Bot 请求使用相应 profile。切换本机看板会显式指定 board，不改变服务端的全局当前看板。不要用另一个普通聊天 session 替代 canonical Bot Chat 来绕过绑定错误。

## 部署前检查

先使用你已有的 Hermes 管理方式确认认证、Bot Mode 和 WebSocket。反向代理应保留部署路径前缀，转发 WebSocket upgrade，并允许长连接。推荐 HTTPS；HTTP 的 ATS 处理见[开始使用](getting-started.md)。

此仓库不包含生产网关安装器，也不修改 Hermes 主机或网络。`Scripts/mock_gateway.py` 只是本机测试 fixture，不能作为生产服务或兼容性保证。

参考：[Hermes Agent](https://github.com/NousResearch/hermes-agent)、[Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode)。上游文档可能领先于你安装的版本，应结合实际服务端接口判断。
