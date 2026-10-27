<p align="center"><img src="Support/BrandLogo.png" alt="MOS" width="100" /></p>
<h1 align="center">MOS</h1>
<p align="center"><strong>Your Hermes agents, at home on your Mac.</strong></p>
<p align="center">A native SwiftUI client for ongoing conversations, scheduled work, and multi-Bot collaboration.</p>
<p align="center">macOS 15+ · Apple Silicon · Swift · MIT · Early Preview</p>
<p align="center"><a href="README.md">简体中文</a> · English · <a href="https://github.com/a2715124502/MOS/releases">Download</a> · <a href="https://github.com/a2715124502/MOS/issues">Feedback</a></p>

## Pick up where you left off

Your Hermes setup may already have a product partner, an engineering assistant, and a Bot for everyday work. Each has its own role, memory, and ongoing conversation.

**MOS brings those assistants into a familiar Mac messaging interface.** Choose a Bot from the contact list and return to its canonical Bot Chat. Share a screenshot, switch models, handle an approval, or check a task board from the same window.

The full project name is **Hermes Mose**; the app and interface display **MOS**. This is an independent community project.

## What you can do

| Workflow | Experience |
| --- | --- |
| Work with several assistants | A Bot roster with pins, unread indicators, work status, and per-Bot drafts |
| Continue an ongoing conversation | Canonical Bot Chat, paginated history, streaming replies, Markdown, and code blocks |
| Share context | Drag files, paste images, and preview attachments before sending; up to 10 files, 25 MB each |
| Stay in control | Stop replies, answer clarifying questions, and review server-provided approval cards |
| Schedule recurring work | Per-Bot schedules and run records, with results delivered to Bot Chat |
| Coordinate work | Shared Kanban boards with owners, priorities, dependencies, logs, results, and notes |
| Configure your assistants | Session model switching, per-profile default/auxiliary/fallback models, tools, Skills, MCP, and messaging platforms |
| Make it yours | Light/dark/system appearance, theme colors, text sizing, adjustable sidebar, and configurable animated avatars |

Closing the main window keeps MOS connected in the menu bar. After quitting MOS, remote schedules continue on Hermes; local notifications stop.

## How it works

MOS connects to **your existing compatible Hermes gateway** over HTTP and WebSocket. Inference, tools, long-term memory, and scheduling run on your Hermes host. You do not need to install Hermes or a model runtime on the client Mac. Provider charges and service configuration belong to your existing Hermes setup.

The integration was developed against Hermes **0.22.4** APIs, including native password/PKCE authentication and canonical Bot Chat. A cross-version compatibility matrix is not yet available. A generic chat API or OpenAI-compatible endpoint alone is insufficient. See [gateway requirements](docs/gateway-compatibility.md) for the actual contract. Optional features need their corresponding server APIs and plugins.

## Get started

1. Download `MOS-0.13.0-Mac-arm64.zip` from [Releases](https://github.com/a2715124502/MOS/releases), unzip, and move `MOS.app` into Applications.
2. Use an **Apple Silicon Mac running macOS 15+**.
3. Enter your own compatible gateway URL, such as `https://hermes.example.com` (an example only), then sign in with its existing Hermes username and password.
4. Choose a Bot and continue its conversation.

The preview is ad hoc signed and **not Developer ID signed or notarized**. macOS may block the first launch. Verify the source and checksum before following the system's Privacy & Security prompts, or build from source; do not disable system security.

Prefer HTTPS. Private networking such as Tailscale can provide reachability, but custom HTTP hosts also need an appropriate macOS ATS exception in a source build. MOS does not configure your VPN. See the [setup guide](docs/getting-started.md), currently in Chinese.

Want to look around first? Choose **“先看看界面”** on the login screen. The built-in example mode needs no account, does not connect to a gateway, and cannot send messages or execute remote work. **The app UI is currently primarily Simplified Chinese**; this English README does not imply an English interface.

## Useful everyday workflows

- Continue a product discussion, switch to an engineering Bot, and return to your original draft.
- Ask a Bot to run a weekly summary and follow up on the result in its ongoing chat.
- Assign board tasks to different Bots with explicit dependencies and inspect their execution records.
- Paste a screenshot, review its preview, add context, and send it to the selected assistant.

These are workflow examples. What your agents can execute depends on your configured models, tools, permissions, and server capabilities.

## Keyboard and controls

| Action | Control |
| --- | --- |
| Send / new line | Return / Shift-Return; confirming a Chinese IME candidate does not send |
| Stop | ⌘. |
| Reconnect | ⌘R |
| Settings | ⌘, |
| Commands | Type `/`, navigate with ↑↓, fill with Return or Tab |
| Chat model | Model name beneath the composer |
| Bot avatar | Chat header avatar or Bot context menu |
| Schedules / boards | Current Bot's top toolbar |

Avatar preferences stay on this Mac, isolated by gateway, account, and profile. They do not change remote roles or memory. A session model selection is separate from changing a profile's default model.

## Data on your Mac

Passwords are used for sign-in and are not persisted. Login tokens use macOS Keychain. Recent chat text and drafts are cached in Application Support, separated by gateway and account, with limits of 16 Bots, 240 messages per Bot, 30 days, and 12 MB per cache file. **This display cache is not encrypted.** Signing out clears the current account's display cache and requests deletion of the gateway's Keychain token.

Requests go to your chosen gateway; its models, tools, and integrations may contact third-party services you configured. See [privacy and local storage](docs/privacy.md).

## Build from source

Use an Apple Silicon Mac, macOS 15+, and Xcode 16+ / Swift 6. There are no third-party Swift package dependencies.

```sh
git clone https://github.com/a2715124502/MOS.git
cd MOS
bash Scripts/build-app.sh
open dist/MOS.app
```

The script packages artwork, fonts, and the icon into `dist/MOS.app`, then ad hoc signs it. Build files stay under `.build/app`. The internal executable target remains `BotClient`; `HermesClient` contains reusable transport and state code. Running the Swift executable directly does not package all app resources.

See [development](docs/development.md) for the layout, optional local fixture, and verification instructions.

## Preview status and roadmap

**0.13.0 is the first open-source preview**, based on the 0.12.1 codebase, with MOS branding, personal deployment defaults removed, and public documentation. Compilation does not establish real-gateway, weak-network, or high-volume scrolling correctness; those still need acceptance testing. See [CHANGELOG.md](CHANGELOG.md) for the release's verification scope.

Intel Macs, iPhone, Watch, voice conversations, group chats, and general session browsing are not provided. Priorities are real-gateway compatibility and long-history checks, clearer connection diagnostics, English UI and accessibility improvements, and Developer ID signing/notarization. These are plans, not released features or dated commitments.

## Contribute

Issues, ideas, documentation fixes, and pull requests are welcome. Include MOS, macOS, and Hermes versions, reproduction steps, and redacted screenshots. Never attach credentials, private hostnames, or private chat history. Read [CONTRIBUTING.md](CONTRIBUTING.md).

If MOS fits your workflow, give it a Star, try the preview, and share what you use it for.

## License and acknowledgments

MOS is [MIT licensed](LICENSE). Bundled JetBrains Mono fonts retain their [SIL Open Font License 1.1](Support/Fonts/JetBrainsMono-OFL.txt).

Thanks to [Hermes Agent](https://github.com/NousResearch/hermes-agent) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono). MOS is independently developed and is not affiliated with or endorsed by Nous Research. See [third-party notices](THIRD_PARTY_NOTICES.md).
