# OrigiLink

A Nostr-based chat app built with Flutter (UI) and Rust (key management, protocol logic, storage), connected via [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge).

## Features

- **1:1 chat** over NIP-59 gift-wrapped direct messages (NIP-17 style), with image/file attachments encrypted separately (via a Blossom-compatible server) and Signal-style Double Ratchet forward + backward secrecy layered on top of the default NIP-44 encryption.
- **Group chat** with no shared group key or single event two members both see — every message is individually re-encrypted per recipient, over a dedicated per-group Nostr identity and pairwise Double Ratchet sessions, so members don't need to already be 1:1 friends with each other.
- **Multi-account key derivation** (NIP-06) — every friendship gets its own unlinkable relationship key, derived from a single BIP-39 seed phrase.
- QR-code-based friend invites, relay management, and account backup/sync over relays.

## Project structure

- `lib/` — Flutter UI: screen layout, input handling, calling into Rust, displaying results.
- `rust/src/` — Rust core: key management, protocol logic, storage/DB. All persistence and crypto logic lives here, not in Dart.
- `lib/src/rust/` — generated Dart bindings for `rust/src/api/**`, produced by `flutter_rust_bridge_codegen` and committed as source.

See [CLAUDE.md](CLAUDE.md) for a detailed architecture walkthrough (screen flow, bridge configuration, storage formats, etc.) aimed at anyone (human or AI) working on the codebase.

## Development

All Flutter/Rust/Android tooling is expected to run inside an `origilink-dev` Docker container (see `docker-compose.yml`), which bind-mounts the repo root at `/workspace`. From the host:

```bash
docker compose up -d
docker exec -w /workspace origilink-dev bash -lc "<command>"
```

Common commands (run inside the container):

```bash
# Install Dart deps (also regenerates localization from the ARB files)
flutter pub get

# Static analysis
flutter analyze lib/

# Run on a connected/emulated device
flutter run -d <device-id> --debug

# Tests
flutter test
flutter test integration_test/simple_test.dart

# Regenerate Dart<->Rust bindings after changing anything under rust/src/api/
flutter_rust_bridge_codegen generate

# Typecheck Rust changes without a full Flutter rebuild
cd rust && cargo check --lib
```

Only Android (and eventually iOS) is actively developed/tested; Web/Windows/Linux desktop builds exist as scaffolding but aren't maintained or verified.

## License

MIT — see [LICENSE](LICENSE).
