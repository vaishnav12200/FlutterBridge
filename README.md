# 🚀 FlutterBridge

> Bridge your Flutter code to your phone instantly. Scan. Connect. Build.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Node](https://img.shields.io/badge/node-%3E%3D18.0.0-brightgreen)
![Flutter](https://img.shields.io/badge/flutter-%3E%3D3.0.0-blue)
![Phase 1](https://img.shields.io/badge/Phase%201-Complete-success)
![Status](https://img.shields.io/badge/status-in%20development-orange)

---

## 📱 What is FlutterBridge?

FlutterBridge is an open-source developer tool that brings an **Expo-like wireless development experience** to Flutter.

No USB cables. No complex ADB setup. Just scan a QR code and start building.

It enables:
- 📡 Wireless connection between your laptop and phone
- 📷 QR code-based device pairing
- ⚡ Hot reload over WiFi
- 🧠 Simple CLI interface — works with any Flutter project

---

## ✨ Features

| Feature | Status |
|---|---|
| QR Code generation in terminal | ✅ Done |
| Flutter VM URL detection | ✅ Done |
| Device selection & error handling | ✅ Done |
| CLI flags (--device, --qr-only, --json) | ✅ Done |
| LAN IP rewriting | ✅ Done |
| NPM package published (npm/pnpm/bun) | ✅ Done |
| Hot reload over WiFi | 📅 Planned (Phase 2) |
| Companion Android app | 📅 Planned (Phase 2) |
| iOS support | 📅 Planned (Phase 5) |
| Plugin support | 📅 Planned (Phase 5) |

---

## 🏗️ Architecture

FlutterBridge consists of two parts:

```
flutterbridge/
│
├── cli/          # Node.js CLI tool
│   └── index.js  # Entry point
│
├── app/          # Flutter companion app (coming soon)
│
├── docs/         # Documentation
│
├── README.md
├── LICENSE
└── CONTRIBUTING.md
```

### How it works

```
[ Your Flutter Project ]
        │
        ▼
[ FlutterBridge CLI ] ──── starts flutter run ──── extracts VM URL
        │
        ▼
[ QR Code in Terminal ]
        │
        ▼ (scan)
[ FlutterBridge App on Phone ] ──── connects ──── shows your app
```

---

## 🚀 Getting Started

### Prerequisites

- [Node.js](https://nodejs.org) >= 18
- [Flutter](https://flutter.dev/docs/get-started/install) >= 3.0
- A physical Android device
- Both PC and phone on the **same WiFi network**

### Installation

#### Option 1: Package Manager (Recommended)

```bash
# Using pnpm (Recommended)
pnpm add -g @vaishnavkm/flutterbridge

# Using npm
npm install -g @vaishnavkm/flutterbridge

# Using bun
bun add -g @vaishnavkm/flutterbridge

# Or use without installation (pnpm)
pnpm dlx @vaishnavkm/flutterbridge

# Or use without installation (npm)
npx @vaishnavkm/flutterbridge

# Or use without installation (bun)
bunx @vaishnavkm/flutterbridge
```

#### Option 2: From Source

```bash
git clone https://github.com/vaishnavkm/flutterbridge.git
cd flutterbridge/cli
pnpm install
```

### Run FlutterBridge

Navigate to your Flutter project and run:

```bash
# If installed globally (works with npm, pnpm, or bun)
bridge

# Or without installation
pnpm dlx @vaishnavkm/flutterbridge # pnpm
npx @vaishnavkm/flutterbridge      # npm
bunx @vaishnavkm/flutterbridge     # bun

# Or from source
node /path/to/flutterbridge/cli/index.js
```

You will see a QR code appear in your terminal.

If the VM service is bound to localhost, FlutterBridge will start a LAN proxy
and encode that address in the QR so phones can connect over WiFi.

### CLI Options

```bash
# Choose a specific device (recommended when multiple devices are connected)
bridge --device <device-id>
bridge -d <device-id>

# Print only the QR code (no extra logs)
bridge --qr-only

# Print machine-readable output (JSON) when the VM URL is ready
bridge --json

# Pass additional Flutter flags
bridge -- --release
bridge -- --flavor production
```

### Connect Your Device

1. Open the **FlutterBridge** app on your phone
2. Scan the QR code
3. Your app will launch instantly 🎉

---

## 🔄 Hot Reload

Make changes in your Flutter code and save. FlutterBridge automatically reflects the updates on your connected device — no USB required.

---

## 📊 Current Status

### ✅ Phase 1: CLI Foundation — COMPLETED

All Phase 1 objectives have been achieved:

- ✅ Robust VM service URL detection from `flutter run --machine`
- ✅ Multi-device handling with interactive selection
- ✅ Comprehensive error handling (missing Flutter, no devices, offline devices)
- ✅ CLI flags: `--device`, `--qr-only`, `--json`
- ✅ LAN IP rewriting for wireless connectivity
- ✅ Chrome web hostname auto-configuration
- ✅ NPM package published (npm/pnpm/bun supported)
- ✅ Complete documentation and contribution guidelines

**The CLI is production-ready and fully functional!**

### ✅ Phase 2: Companion App MVP — COMPLETED

All Phase 2 objectives have been achieved:

- ✅ QR scanner UX, URL validation, manual input fallback
- ✅ VM service WebSocket connection with reconnect + token validation
- ✅ Hot reload + hot restart controls with status
- ✅ Remote logs panel with filters and timestamps
- ✅ Bottom navigation: Home / Logs / Devices / Settings
- ✅ Live App Preview: Streams live screenshots from the device to the companion app over WebSocket!

---

## 🛣️ Roadmap (Detailed, ordered)

### Phase 1 — Solid CLI foundation ✅ COMPLETED
1. **Reliable VM service URL detection** ✅
        - Parse `flutter run --machine` JSON events (not stdout text).
        - Handle multi-device output; choose default or prompt.
        - Retry until `vmServiceUri` appears; time out with clear error.
2. **Error handling and guardrails** ✅
        - Detect missing Flutter, not-a-Flutter-project, no devices, or offline device.
        - Provide actionable fixes (commands or links).
3. **CLI flags and UX** ✅
        - `--device <id>` to force device selection.
        - `--qr-only` to print QR without extra logs.
        - `--json` for machine-readable output (future automation).
4. **Packaging and distribution** ✅
        - Package configured for npm publishing.
        - Published as `@vaishnavkm/flutterbridge` with `npx` and global install support.

### Phase 2 — Companion App MVP ✅ COMPLETED

The companion app is the heart of FlutterBridge. This phase delivers a working
Android app that connects to the CLI over WiFi and gives developers a real-time
window into their running Flutter app.

#### 2.1 QR Scanner Screen
- ✅ Camera permission handling with graceful fallback UI
- ✅ Real-time QR scanning using `mobile_scanner` package
- ✅ URL validation — reject malformed or non-FlutterBridge QR codes
- ✅ Manual URL input fallback (paste the URL shown in terminal)
- ✅ Visual feedback: scanning → connecting → connected states

#### 2.2 VM Service WebSocket Connection
- ✅ Parse scanned URL and establish WebSocket to `vmServiceUri`
- ✅ Connection state management: connecting / connected / disconnected / error
- ✅ Auto-reconnect with exponential backoff if WiFi drops
- ✅ Clear error messages with actionable hints (wrong network, firewall, etc.)
- ✅ Token validation for secure pairing (matches token embedded in QR)

#### 2.3 Hot Reload from Phone
- ✅ One-tap hot reload button in the companion app
- ✅ Invokes `callServiceExtension('hotReload')` over VM service WebSocket
- ✅ Shows reload status: triggered → rebuilding → done / error
- ✅ Reload duration display (e.g. "Hot reload in 312ms")
- ✅ Hot restart support as a secondary option

#### 2.4 Remote Logs
- ✅ Stream live logs via `streamListen('Logging')` over VM service
- ✅ Filter tabs: All / Debug / Info / Warn / Error
- ✅ Color-coded log levels matching Flutter's log severity
- ✅ Timestamp display per log entry
- ✅ Source file + line number shown below each log
- ✅ Clear logs button and auto-scroll toggle

#### 2.5 Bottom Navigation
- ✅ **Home** — connection status, device info, quick actions
- ✅ **Logs** — live log stream with filters
- ✅ **Devices** — list of connected/available devices
- ✅ **Settings** — app preferences, connection history

---

### Phase 3 — Networking + Security + Reliability 🔒

#### 3.1 Robust LAN Connectivity
- Detect and display local IP automatically in CLI
- Verify phone can reach the host before showing QR (ping check)
- Firewall detection — warn if port is blocked with fix instructions
- Multi-network interface support (pick the right IP when multiple adapters exist)
- Proxy server built into CLI for localhost-bound VM URLs (already partially done)

#### 3.2 Secure Pairing
- Generate a short random token per session (embedded in QR)
- CLI WebSocket server validates token on every connection attempt
- Reject and log unauthorized connection attempts
- Session expiry — token invalidates after disconnect or timeout
- Optional persistent pairing: remember trusted devices by fingerprint

#### 3.3 Stability & Error Recovery
- CLI watches for `flutter run` crashes and notifies companion app
- Companion app detects stale connections and prompts reconnect
- Handle VM service port changes between hot restarts
- Detailed error codes with user-facing fix suggestions
- Unit tests for VM URL parsing, device selection, and token validation

---

### Phase 4 — Live Screen Streaming (Expo-like Preview) 📡

This is the flagship feature — making FlutterBridge feel truly like Expo. The
companion app shows a **live video stream** of the running Flutter app, so the
phone becomes a real-time preview window.

#### 4.1 Screen Capture Pipeline ✅ (Basic Polling Implemented)
- ✅ CLI runs `adb exec-out screencap -p` to grab device frames
- 🚧 Fast Android `MediaCodec` pipeline (Planned for Full version)
- ✅ Frames streamed from device → CLI over WebSocket

#### 4.2 MJPEG Streaming (Phase 4 Alpha) ✅ COMPLETED
- ✅ CLI receives frames and streams them as raw JPEG over WebSocket
- ✅ Companion app connects to WebSocket endpoint on LAN
- ✅ Renders live preview directly within the Home screen
- ✅ Low implementation complexity, ships fast as a proof of concept
- 🚧 Shown fullscreen in companion app with overlay controls (Next)

#### 4.3 WebRTC Streaming (Phase 4 Full)
- Replace MJPEG with WebRTC peer connection for true low-latency streaming
- CLI acts as WebRTC signaling server (via existing WebSocket)
- H.264 encoded stream delivered peer-to-peer over LAN
- Target: 30–60 fps, < 150ms latency on local WiFi
- Uses `flutter_webrtc` package in companion app for rendering
- Adaptive quality — drops resolution if network degrades

#### 4.4 Preview UI in Companion App
- Full-screen live preview tab added to bottom navigation
- Device frame overlay (Pixel, iPhone shape) around the stream
- Pinch to zoom, tap to focus controls
- Screenshot capture button — saves frame to phone gallery
- Stream quality indicator (fps, latency, resolution)

#### 4.5 Emulator Support
- For emulators (no physical device), CLI captures the emulator window directly
- Uses `adb emu screenrecord` or virtual display capture
- Same WebRTC pipeline, no ADB push needed for emulator targets

---

### Phase 5 — Platform Expansion + Advanced Features 🌐

#### 5.1 Touch Forwarding
- Tap events on the companion app preview are forwarded back to the running Flutter app
- CLI receives touch coordinates from companion → injects via ADB input
- Supports: tap, swipe, scroll, long press
- Coordinate mapping accounts for stream scaling and device frame offset
- Makes the companion app a full remote control for the running app

#### 5.2 iOS Support
- iOS device discovery via `ios-deploy` or Xcode instruments
- VM service URL extraction from `flutter run` targeting iOS simulator / device
- Same QR pairing flow, same companion app (cross-platform Flutter)
- Screen capture via `ReplayKit` framework on iOS
- Note: iOS streaming has stricter privacy restrictions than Android — handled with explicit user prompt

#### 5.3 Multi-Device Support
- Run FlutterBridge once, connect multiple phones simultaneously
- Each device gets its own stream and log view
- CLI manages multiple ADB sessions in parallel
- Companion app shows device switcher when multiple sessions are active
- Useful for testing responsive layouts across screen sizes at once

#### 5.4 Plugin Support & Compatibility Layer
- Document known incompatible plugins (camera, bluetooth, etc. need real device)
- Compatibility checker in CLI warns before running if incompatible plugins detected
- Plugin override hooks for common packages

#### 5.5 CI/CD & Automation Integration
- `--json` flag output stable and documented for scripting
- GitHub Actions example workflow using FlutterBridge for device testing
- Slack / webhook notification on crash or hot reload failure
- Screenshot diff tool — compare frames across builds automatically

---

## ⚠️ Limitations

- Requires both devices on the **same WiFi network**
- Currently **debug mode only**
- Limited plugin support in early versions
- Android only (iOS coming later)

---

## 🤝 Contributing

Contributions are welcome! Here's how to get started:

1. Fork the repository
2. Create your feature branch
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. Commit your changes
   ```bash
   git commit -m "feat: add your feature"
   ```
4. Push to your branch
   ```bash
   git push origin feature/your-feature-name
   ```
5. Open a Pull Request

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## 💡 Inspiration

Inspired by the seamless developer experience of [Expo](https://expo.dev) for React Native. Flutter deserves the same.

---

## 🌟 Support

If you find this project useful:
- ⭐ Star the repo
- 🍴 Fork it
- 🧑‍💻 Contribute
- 📢 Share it with fellow Flutter devs

---

## 👨‍💻 Author

**Vaishnav K M**  
Built with ❤️ for the Flutter community.

---

> 🚀 *FlutterBridge aims to become the standard development experience for Flutter — making app testing as simple as scanning a QR code.*