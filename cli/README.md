# FlutterBridge CLI

> Wireless Flutter development with QR code pairing

Bridge your Flutter code to your phone instantly. No USB cables. No complex ADB setup.

## Installation

### Global Installation

```bash
# Using npm
npm install -g @vaishnavkm/flutterbridge

# Using pnpm
pnpm add -g @vaishnavkm/flutterbridge

# Using bun
bun add -g @vaishnavkm/flutterbridge
```

### One-time Use (No Installation)

```bash
# Using npm
npx @vaishnavkm/flutterbridge

# Using pnpm
pnpm dlx @vaishnavkm/flutterbridge

# Using bun
bunx @vaishnavkm/flutterbridge
```

## Usage

Navigate to your Flutter project directory and run:

```bash
flutterbridge
```

A QR code will appear in your terminal. Scan it with the FlutterBridge companion app to connect.

## CLI Options

```bash
# Choose a specific device
flutterbridge --device <device-id>
flutterbridge -d <device-id>

# Print only the QR code (no extra logs)
flutterbridge --qr-only

# Print machine-readable JSON output
flutterbridge --json

# Pass additional Flutter flags
flutterbridge -- --release
flutterbridge -- --flavor production
```

## Requirements

- Node.js >= 18
- Flutter >= 3.0
- Package manager: npm, pnpm, or bun
- Both PC and phone on the same WiFi network

## Troubleshooting

### "Flutter was not found on your PATH"
Install Flutter: https://flutter.dev/docs/get-started/install

### "No pubspec.yaml file found"
Run the command from the root of your Flutter project.

### "No devices found"
- Connect a physical device via USB
- Start an Android/iOS emulator
- Run `flutter devices` to verify

### "Found offline/unauthorized devices"
- Enable USB debugging on your device
- Run `adb devices` and authorize the device
- Reconnect your device

### Connection fails
- Ensure both devices are on the same WiFi network
- Check firewall settings
- Try disabling VPN

## Documentation

Full documentation: https://github.com/vaishnavkm/flutterbridge

## License

MIT © Vaishnav K M
