# 开发指南

## 构建

使用 Apple Silicon Mac、macOS 15+、Xcode 16+ / Swift 6；Xcode 的 Command Line Tools 需指向可用的开发工具链。没有第三方 Swift 包依赖。

```sh
bash Scripts/build-app.sh
```

输出 `dist/MOS.app`；默认 scratch path 是 `.build/app`，可用 `BOTCLIENT_SCRATCH_PATH` 覆盖，应用输出可用 `BOTCLIENT_APP_PATH` 覆盖。脚本使用 arm64 Release，复制 Logo、头像数据和字体／许可，生成 icns 并 ad hoc 签名。ad hoc 不能替代 Developer ID 签名与公证。

```sh
codesign --verify --deep --strict dist/MOS.app
plutil -p dist/MOS.app/Contents/Info.plist
```

可以在 Xcode 打开 `Package.swift` 阅读和编译。内部目标名为 `BotClient`，通信库为 `HermesClient`。完整资源依赖应用打包，不能用单独启动 Swift 可执行文件代替分发包。

## 结构

```text
Sources/
  BotClient/         SwiftUI / AppKit 界面、主题、输入、头像、消息呈现
  HermesClient/      HTTP / WebSocket、认证、会话、缓存与 profile 配置
Support/             Info.plist、Logo、矢量头像数据、字体及许可
Scripts/             应用打包、图标生成、本机协议 fixture
Tests/               通信契约、会话／工作区、凭据与头像偏好测试
docs/                使用、兼容、隐私与开发文档
```

品牌名称 MOS 与内部目标名分离。`local.hermes.remote` bundle ID、钥匙串服务和已有偏好键保持兼容，避免升级时更换身份。服务端 profile 名称不应通过展示名推断。

## 可选验证方式

以下是贡献者在自行授权的环境中可执行的步骤，不代表本次发布已运行这些测试。

不启动 fixture：

```sh
swift test --scratch-path .build/tests
```

依赖 HTTP／WebSocket fixture 的用例在缺少 `HERMES_FIXTURE_URL` 时会跳过；“命令成功”不能单独证明全部集成用例已执行。

完整本机 fixture 需要 Python 3 与 `aiohttp`，可使用独立虚拟环境。终端 A：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install aiohttp
HERMES_FIXTURE_PORT=19119 .venv/bin/python Scripts/mock_gateway.py
```

终端 B：

```sh
HERMES_FIXTURE_URL=http://127.0.0.1:19119 swift test --scratch-path .build/tests
```

fixture 仅监听 loopback，使用明确的 `fixture`／`fixture-password` 合成凭据，不联系真实 Hermes；完成后在终端 A 使用 Ctrl-C 停止。它覆盖的历史协议行为不构成当前生产版本的兼容性证明，新增 API 应扩展对应 fixture 与用例。

手动查看示例界面可在自行允许运行应用时使用：

```sh
open dist/MOS.app --args --demo
```

不要自动使用开发机已保存的真实登录做测试。真实网关验收需要独立授权、明确账号和可回滚的任务数据。性能／快速滚动应在原生应用上检查，静态图或 HTML 不能替代。

## 打包发布

```sh
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent dist/MOS.app dist/MOS-0.13.0-Mac-arm64.zip
shasum -a 256 dist/MOS-0.13.0-Mac-arm64.zip
```

发布前核对：版本、最低系统、arm64、字体许可、资源与签名，并明确本版实际编译／运行验收范围。源码仓库不提交 `.build`、应用包、凭据或私人日志；分发包放 Releases。
