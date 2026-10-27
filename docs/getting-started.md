# 开始使用 MOS

## 准备条件

- Apple Silicon Mac，macOS 15 或以上。
- 自己运行的兼容 Hermes 网关、账号和可访问地址。Mac 不需要本地安装 Hermes。
- 网关需启用原生密码登录／PKCE、WebSocket 和 canonical Bot Chat；见[兼容要求](gateway-compatibility.md)。MOS 不负责安装服务端。

如果尚未部署 Hermes，从 [Hermes Agent 官方仓库](https://github.com/NousResearch/hermes-agent)及[官方文档](https://hermes-agent.nousresearch.com/docs/)开始。按你使用的 Hermes 版本配置访问、认证与 Bot profiles，再核对 MOS 接口要求；不要把模型服务的 API 地址填成 Hermes 网关地址。

## 下载与校验

在 [Releases](https://github.com/a2715124502/MOS/releases) 下载匹配版本的 Mac arm64 ZIP 和 `SHA256SUMS.txt`，放在同一文件夹。进入该目录后可核对：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

如果只下载了其中一个 ZIP，校验工具会报告另一个文件缺失；核对你下载的那一项为 `OK` 即可。校验失败时重新下载，不要运行该文件。

解压，将 `MOS.app` 移入“应用程序”。预览版使用 ad hoc 签名，尚未经过 Apple Developer ID 签名和公证。macOS 可能阻止首次打开；核对来源后按系统“隐私与安全性”提示处理，或[自行构建](development.md)。无需关闭 Gatekeeper 或全局修改隔离属性。

## 首次连接

1. 打开 MOS，填入你自己的 Hermes 网关根地址，例如 `https://hermes.example.com`（示例，需替换）。反向代理有路径前缀时保留前缀。
2. 使用该网关的 Hermes 用户名和密码登录。这里不是模型服务商的账号或 API key。
3. 点击左侧 Bot，进入其固定 Bot Chat。MOS 读取远端 profiles，不会在客户端创建一套新的长期记忆。

网关地址与用户名保存在本机偏好，令牌保存在钥匙串；密码不持久保存。使用过早期版本时，同一 bundle ID 会沿用原有偏好，因此旧网关地址仍可能显示。

## 示例模式

登录页点击“先看看界面”。内置消息与 Bot 是示例，不需要网关，也不能发送或执行真实任务。要连接自己的服务，请退出示例模式后登录。

## HTTP、HTTPS 与私有网络

推荐 HTTPS。应用保留 macOS 的 ATS 保护，以及本地网络访问配置和 `127.0.0.1` 的显式 HTTP 例外，不包含任何个人网关的预授权地址。

私有网络或 Tailscale 解决的是网络可达性，不自动解决 ATS 对明文 HTTP 的限制。你已有的私有网络可以继续使用，MOS 不修改它。

如果必须使用特定的 HTTP 网关，可在自己的源码副本中编辑 `Support/Info.plist`，为实际主机添加精确的 `NSExceptionDomains` 条目后重新构建。域名不带 scheme、端口或路径，不要将示例域名原样加入：

```xml
<key>NSExceptionDomains</key>
<dict>
    <!-- Replace this example with your actual gateway host. -->
    <key>gateway.example.com</key>
    <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key>
        <true/>
    </dict>
</dict>
```

将条目合并到现有字典，保留需要的本机条目。不同地址形式的 ATS 行为需在你的系统上验证；对于 IP 字面量，优先改为可信 HTTPS 或可解析的网关主机名。不要设置全局 `NSAllowsArbitraryLoads` 来绕过所有地址的保护。明文 HTTP 不提供传输加密。

## 常见问题

### 地址可访问，但登录失败

MOS 需要 `/auth/native/authorize`、`/auth/password-login`、`/auth/native/token` 等原生认证接口。仅能打开网页、普通 Basic Auth 或模型 API 并不表示这些接口可用。检查用户名密码、反向代理路径、Hermes 版本和[接口要求](gateway-compatibility.md)。

### 登录后连接失败或一直重连

确认反向代理允许 WebSocket 升级，且 `/api/auth/ws-ticket` 和 `/api/ws` 可由该账号访问。不要把凭据、票据或完整带查询参数的 URL 放进公开 issue。

### Bot 列表为空

确认远端已有 Bot profile、当前账号有访问权限，且 `profiles.list` 能返回列表。MOS 仅接续 canonical Bot Chat，不从“最近一个普通 session”猜测会话。参见 [Hermes Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode)。

### 看板、定时任务或平台配置不可用

这些依赖远端对应接口／插件；不是独立的本地服务。检查网关返回的错误、功能启用状态和版本。MOS 当前不提供安装服务端插件的通用管理器。

### 看不到通知

允许 macOS 通知，并保持 MOS 运行及连接。关闭窗口可继续留在菜单栏；完全退出后不会接收通知，也没有额外的 APNs 服务。

### 想清除当前账号的缓存和登录状态

使用设置中的退出登录。它会清除当前账号显示缓存并请求清除该网关令牌，保留外观等偏好；其他账号／网关的数据不受该操作影响。更多信息见[本机数据说明](privacy.md)。
