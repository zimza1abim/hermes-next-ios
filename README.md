# Hermes Next for iOS

A native iPhone and iPad client for a [Hermes](https://github.com/NousResearch/hermes-agent) Webapp
server. It talks to the server's own gateway socket and HTTP API, so the chats, bots and settings are
the same ones you see in the Webapp and on other devices. No web page is loaded for chatting.

Bundle id `dev.hermes.next`, version 1.0.0, iOS 17 or later.

## Features

- **Chats.** Every chat of every bot in one list, newest first, plus one tab per bot. Swipe sideways
  between tabs. Search by title or text.
- **Sections.** Bot chats, app chats, each messaging platform (Telegram, Discord, ...) and cron runs
  are listed apart.
- **Live answers.** Answers stream in as they are written. Stop a running answer. Approve or deny a
  command Hermes asks to run.
- **Readable answers.** Headings, lists, quotes, tables and code blocks drawn as an editor pane with
  line numbers, token colors and a copy button.
- **Chat actions.** Long-press a chat to rename, pin, archive or delete it. Archived chats can be
  brought back from the menu.
- **Unread marks.** A chat with a new answer blinks until it is opened; opening it marks it read on
  every device.
- **Bots.** Each bot's picture and name; a new chat starts with the bot of the open tab.
- **Menu.** Cron jobs (run now, pause, resume), the skills, toolsets and MCP servers a bot has, and
  installing catalog plugins and MCP servers. Every list can be searched.
- **Fonts.** Pick any iOS font or import TTF, OTF or TTC files. The font is registered before the first
  frame and applies to every screen.
- **iPad.** The chat list sits beside the conversation; text keeps a readable line length.

## Requirements

- A Hermes Webapp server with the gateway enabled (`/api/webapp/socket-ticket` and `/api/ws`).
- An account on that server. Sign-in happens on the server's own page inside the app.

## Build

Open `HermesNext.xcodeproj` in Xcode 16 or later, choose your team under
**Signing & Capabilities**, and run on a device or simulator.

Compile without signing:

```sh
xcodebuild -project HermesNext.xcodeproj -scheme HermesNext \
  -sdk iphoneos -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

To install without a paid developer account, package the unsigned app as an IPA
(`Payload/HermesNext.app`, zipped) and add it to a sideloading tool such as LiveContainer, AltStore
or Sideloadly. A free account can have only three self-signed apps installed on a device at a time.

## Privacy

- The app connects only to the server address you enter. There is no analytics, tracking or crash
  reporting.
- Sign-in cookies are kept in the iOS keychain on the device, so a restart does not sign you out.
  The server rotates them; the app always keeps the newest copy.
- Chat previews, the draft you are typing, bot pictures and imported fonts are stored in the app's
  own container and never leave the device.

## Not included

Notifications (iOS closes the socket in the background), photo attachments, the model picker and
answering Hermes's clarifying questions. Use the Webapp for those.

## Layout

| File | What it does |
|---|---|
| `Server.swift` | Signed HTTP requests, one at a time (the sign-in uses single-use refresh tokens), cookie storage, and the parsers for the server's lists. |
| `Store.swift` | The gateway socket (JSON-RPC over WebSocket) and all the state the screens show. |
| `ChatListView.swift` | The chat list, tabs and chat actions. |
| `ConversationView.swift` | One conversation and the input field. |
| `MenuView.swift` | Cron, capabilities, install, archive, fonts and server settings. |
| `Markdown.swift`, `MarkdownView.swift` | Parsing and drawing answers. |
| `Fonts.swift` | Font registration and the app-wide text style. |
| `Theme.swift` | Colors and shared controls. |

## Credits

The color palette and the app icon come from
[hermes-android](https://github.com/hermes-webui/hermes-android) (MIT). This project is not affiliated
with Nous Research.

## License

MIT. See [LICENSE](LICENSE).
