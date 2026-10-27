<p align="center">
  <img src="Support/BrandLogo.png" alt="MOS" width="100" />
</p>

<h1 align="center">MOS</h1>
<p align="center"><strong>让你的 Hermes 助手，住进 Mac。</strong></p>
<p align="center">原生 SwiftUI 客户端，把持续对话、定时任务与多 Bot 协作放在一起。</p>
<p align="center">macOS 15+ · Apple Silicon · Swift · MIT · Early Preview</p>
<p align="center">
  简体中文 · <a href="README.en.md">English</a> ·
  <a href="https://github.com/a2715124502/MOS/releases">下载预览版</a> ·
  <a href="docs/getting-started.md">开始使用</a> ·
  <a href="https://github.com/a2715124502/MOS/issues">反馈与建议</a>
</p>

## 打开 Mac，继续和熟悉的助手工作

你可能已经在 Hermes 中养成了几个长期协作的助手：一个帮你梳理产品，一个负责开发，还有一个照顾日常事务。它们各自有角色、记忆和一直延续的对话。

**MOS 把这些助手放进熟悉的 Mac 聊天界面。** 左边是 Bot 联系人，右边是你们的消息；打开一个助手，就回到它的固定 Bot Chat。发一张图、切换模型、处理审批，或把想法交给看板，在同一个窗口继续。

产品全称 **Hermes Mose**，界面与应用名称统一展示为 **MOS**。这是独立的社区项目。

## 为什么使用 MOS

| 你想做的事 | MOS 提供的体验 |
| --- | --- |
| 和多个专业助手长期协作 | 联系人列表、置顶、未读提示与工作状态；每个 Bot 保留独立草稿 |
| 接着上次的对话继续 | 接续 Hermes canonical Bot Chat，历史分页、Markdown、代码块与流式回复 |
| 把图片和文件交给助手 | 拖入文件、粘贴图片、发送前预览；每次最多 10 个附件，单个最大 25 MB |
| 在任务执行时保持掌控 | 停止回复、审批与补充问题卡片；处理状态默认收起 |
| 安排持续发生的工作 | 按 Bot 管理定时任务，查看运行记录，让结果回到对话 |
| 让多个 Bot 一起推进项目 | 共享 Kanban，分配负责人、优先级与依赖，查看日志、结果与备注 |
| 为不同助手选择合适的能力 | 当前会话模型切换；逐 Bot 配置默认、辅助与备用模型，以及工具、Skills、MCP 和消息平台 |
| 用得舒服，也有一点个性 | 系统／浅色／深色外观、主题色、字号、可调侧栏与可配置动态女孩头像 |

关闭聊天窗口后，MOS 仍可在菜单栏保持连接并显示通知。完全退出 MOS 后，远端 Hermes 继续执行已安排的任务；本机停止接收通知。

## 它如何工作

```text
你的 Mac                         你自己的 Hermes 主机
┌──────────────────┐             ┌────────────────────────┐
│ MOS · SwiftUI    │  HTTP / WS  │ 认证与 Bot Chat         │
│ 对话 / 附件 / 审批 │ ◀─────────▶ │ profiles / 记忆 / 工具   │
│ 定时任务 / 看板    │             │ 模型 / 定时调度 / Kanban │
└──────────────────┘             └────────────────────────┘
```

Mac 上无需安装 Hermes 或模型运行环境。你需要一台已经运行 **兼容 Hermes 网关**的主机，以及自己的网关地址和账号。推理、工具执行、长期记忆与任务调度都由该主机负责；模型费用与服务配置沿用你的 Hermes。

MOS 使用 Hermes 的原生密码登录／PKCE、HTTP API 与 WebSocket 接口。接口开发基线为 Hermes **0.22.4**；目前没有覆盖不同 Hermes 版本的兼容性矩阵。仅有一个聊天 API 或 OpenAI 兼容端点不足以连接 MOS。详细要求见[网关兼容说明](docs/gateway-compatibility.md)。

## 几分钟开始

### 1. 安装

从 [Releases](https://github.com/a2715124502/MOS/releases) 下载 `MOS-0.13.0-Mac-arm64.zip`，解压后将 `MOS.app` 放入“应用程序”。需要 **Apple Silicon Mac、macOS 15 或更高版本**。

预览版使用 ad hoc 签名，尚未完成 Apple Developer ID 签名与公证。macOS 可能阻止首次打开；请先核对下载来源与校验和，再按系统“隐私与安全性”中的提示处理。也可以自行构建，无需关闭系统安全机制。

### 2. 连接自己的 Hermes

1. 确认你的 Mac 能访问 Hermes 网关，且该网关提供 MOS 所需接口。
2. 填入自己的网关地址，例如 `https://hermes.example.com`。这是示例域名，需替换为你的地址。
3. 使用该网关已有的 Hermes 用户名和密码登录。
4. 点击左侧 Bot，继续它的固定对话。

建议使用 HTTPS。私有网络／Tailscale 也可用于访问网关；自建 HTTP 地址还需满足 macOS ATS 策略，见[连接与常见问题](docs/getting-started.md)。MOS 不配置或管理你的 VPN。

### 3. 先看看界面

登录页点击 **“先看看界面”**，无需账号即可查看内置示例。示例模式不连接网关，不发送消息，也不执行远端任务。

## 几个适合开始的场景

- **日常工作搭档**：打开产品 Bot 继续讨论需求，切到开发 Bot 推进实现，再回到原来的草稿。
- **定期汇总**：为某个 Bot 安排每周汇总，之后在同一个对话中查看结果并追问。
- **多助手协作**：把工作拆成看板任务，明确负责人和依赖，查看各个 Bot 的执行记录。
- **随手交付材料**：将截图粘贴到输入区，先确认图片和说明，再发给当前助手。

这些是使用思路。实际可执行的工作取决于你在 Hermes 中配置的模型、工具、权限与服务端能力。

## 常用操作

| 操作 | 方式 |
| --- | --- |
| 发送／换行 | Return / Shift-Return；中文输入法确认候选时不会直接发送 |
| 停止回复 | ⌘. |
| 重新连接 | ⌘R |
| 打开设置 | ⌘, |
| 查看命令 | 输入 `/`，使用 ↑↓ 选择，Return 或 Tab 填入 |
| 切换聊天模型 | 点击输入区底部模型名称 |
| 更换 Bot 头像 | 点击聊天顶部头像，或右键 Bot |
| 定时任务／共享看板 | 当前 Bot 顶部工具栏 |

头像偏好仅保存在本机，按网关、账号和 profile 隔离；更换头像不修改 Bot 的角色或记忆。当前会话的模型切换与设置中的 profile 默认模型是两个独立操作。

## 数据与隐私

- 密码用于登录，不持久保存；登录令牌保存在 macOS 钥匙串。
- 历史显示缓存与草稿保存在本机 Application Support，按账号与网关隔离。最多缓存 16 个 Bot、每个 240 条消息，最长 30 天、单文件不超过 12 MB。
- 显示缓存含聊天正文，**不是加密存储**；附件暂存用于上传与本次预览。主动退出登录会清除当前账号的显示缓存并请求清除对应网关的钥匙串令牌。
- 消息与配置请求发往你指定的网关；远端 Hermes 的工具、模型和集成可能继续联系你配置的第三方服务。

详见[隐私与本机数据说明](docs/privacy.md)。

## 从源码构建

需要 Apple Silicon Mac、macOS 15+、Xcode 16+ / Swift 6 工具链。应用无第三方 Swift 包依赖；使用系统 SwiftUI、AppKit、Foundation、Security 等框架。

```sh
git clone https://github.com/a2715124502/MOS.git
cd MOS
bash Scripts/build-app.sh
open dist/MOS.app
```

默认产物为 `dist/MOS.app`，构建目录为 `.build/app`。脚本生成图标、复制字体与头像资源，并执行 ad hoc 签名。Swift 包中的内部可执行目标仍叫 `BotClient`，共享通信模块为 `HermesClient`；直接 `swift run` 不会打包完整应用资源。

模块结构、可选本机 fixture 与验证方式见[开发指南](docs/development.md)。

## 当前状态与接下来

**0.13.0 是首个开源预览版。** 基于 0.12.1 源码整理，统一 MOS 展示名，移除个人默认地址，补齐面向公共使用的文档。

当前界面以简体中文为主。Intel Mac、iPhone、Watch、语音对话、群聊和通用会话浏览暂未提供。定时任务、看板及配置管理依赖网关提供对应能力。真实网关端到端、弱网和大量消息滚动仍需要进一步验收，不能将“编译通过”理解为这些场景已验证。发布验证范围见[更新记录](CHANGELOG.md)。

接下来优先处理：

- 补齐真实网关兼容性与长对话验收。
- 改善首次连接时的能力与错误提示。
- 完善英文界面与键盘／辅助功能体验。
- 准备 Developer ID 签名、公证及更方便的更新分发。

这些是方向，不代表已经提供，也没有承诺完成日期。

## 一起完善 MOS

欢迎提交问题、想法、文档修订和 Pull Request。连接报错、长对话体验、原生交互与可访问性反馈尤其有帮助。请附上 MOS／macOS／Hermes 版本、复现步骤及脱敏截图，避免上传聊天正文、凭据或私人地址。参与方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

如果 MOS 适合你的工作方式，欢迎 Star、试用，并分享你的使用场景。

## 许可与致谢

MOS 使用 [MIT License](LICENSE)；随包的 JetBrains Mono 字体按 [SIL Open Font License 1.1](Support/Fonts/JetBrainsMono-OFL.txt) 分发。

感谢 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 提供远端 Agent 能力，以及 [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) 提供代码字体。MOS 是独立社区客户端，与 Nous Research 无官方隶属或背书关系。字体与品牌资产说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
