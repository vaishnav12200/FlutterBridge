# FlutterBridge Roadmap

This roadmap is ordered. Each milestone builds on the previous one.

## Milestone 1: CLI foundation ✅ COMPLETED
- [x] Terminal QR code generation
- [x] Parse `flutter run --machine` JSON events for `vmServiceUri`
- [x] Multi-device detection with selection prompt
- [x] Clear errors for no devices, bad project, or missing Flutter
- [x] Offline device detection with actionable hints
- [x] CLI flags: `--device`, `--qr-only`, `--json`
- [x] LAN IP rewriting for wireless connectivity
- [x] Chrome web hostname auto-configuration
- [x] Package published to npm registry
- [x] Available via npm/pnpm/bun (`@vaishnavkm/flutterbridge`)

## Milestone 2: Companion app MVP
- [ ] QR scanner screen with permissions
- [ ] Connect to VM service URL (WebSocket)
- [ ] Basic status UI: connected, disconnected, error
- [ ] Trigger hot reload and show reload status

## Milestone 3: Networking + security
- [ ] Same-LAN reachability checks
- [ ] Troubleshooting hints for firewalls and routing
- [ ] Optional pairing token embedded in QR

## Milestone 4: Developer experience + docs
- [ ] Structured CLI status output
- [ ] Quickstart and troubleshooting docs
- [ ] CI checks and unit tests (parsing, device selection)

## Milestone 5: Platform expansion
- [ ] iOS support parity
- [ ] Plugin support evaluation and documentation
