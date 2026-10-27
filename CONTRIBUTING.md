# Contributing to MOS

欢迎使用中文或英文提交反馈与 Pull Request。

## 提交问题

请提供 MOS 版本、macOS 版本、芯片类型、Hermes 版本、最小复现步骤、期望与实际结果。说明是在示例模式、本机 fixture 还是自己的真实网关上发生。

不要附上密码、令牌、Keychain 导出、私人网关地址、完整日志或聊天历史。截图请遮挡账号和消息内容。安全问题请先阅读 [SECURITY.md](SECURITY.md)。

## 提交改动

1. Fork 仓库，新建一个描述明确的分支。
2. 保持改动聚焦：界面在 `Sources/BotClient`，通信与状态在 `Sources/HermesClient`。
3. 使用 `bash Scripts/build-app.sh` 检查完整应用打包；需要验证逻辑或协议时，使用[开发指南](docs/development.md)中的本机测试方式。
4. 在 PR 中说明用户遇到的问题、改动后的行为、实际验证范围和未验证项。界面改动可附脱敏截图。

未经明确授权，不要使用其他人的生产网关、账号或真实任务做测试。测试与截图优先使用内置示例或本机 fixture。不要为解决客户端问题而修改用户的 VPN 或系统网络。

请保留 canonical Bot Chat、逐 profile 路由、服务端审批与不确定发送不自动重试的行为。协议变更需说明兼容条件；不要硬编码个人地址、模型列表或凭据。

提交贡献即表示你有权提供这些内容，并同意按项目 MIT License 分发；第三方内容须保留原许可。
