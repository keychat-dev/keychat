# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Dev environment

All Flutter/Rust/Android tooling lives **only inside the `keychat-dev` Docker container**, not on the host. The host has no `flutter`, `adb`, or Android SDK. Always run commands via:

```bash
docker exec -w /workspace keychat-dev bash -lc "<command>"
```

The container is started via `docker-compose.yml` (`network_mode: host`, so the container's `adb` can reach an Android emulator running on the host). If it isn't running, start it with `docker compose up -d` (or open the `.devcontainer`). `/workspace` inside the container is a bind mount of the repo root.

**Ownership gotcha**: the container runs as `root`, so files it creates (build artifacts, generated code, `flutter pub get` output) appear root-owned on the host bind mount and become uneditable by the host user. After the container writes new files/dirs, fix ownership from the host:

```bash
docker exec keychat-dev bash -lc "chown -R 1000:1000 /workspace/<path>"
```

## Commands

```bash
# Install Dart deps (also triggers ARB -> AppLocalizations codegen via `generate: true`)
flutter pub get

# Static analysis
flutter analyze lib/

# Run on a device (list devices first with `flutter devices`)
flutter run -d emulator-5554 --debug

# Widget/unit tests
flutter test

# Integration test
flutter test integration_test/simple_test.dart

# Regenerate Dart<->Rust bindings after changing anything under rust/src/api/
flutter_rust_bridge_codegen generate
```

Rust itself is never built with `cargo build` directly — `flutter run`/`flutter build` invoke it through the Native Assets build hook (`hook/build.dart`), which drives `flutter_rust_bridge_hooks` against `rust/` (no `cargokit`).

## Architecture

**Split**: Flutter (`lib/`) owns UI only — screen layout, input, calling into Rust, displaying results. Rust (`rust/src/`) owns all key management, protocol logic, and storage/DB operations. Don't put persistence or crypto logic in Dart.

**Flutter <-> Rust bridge**: `flutter_rust_bridge` (pinned to `2.13.0-beta.4`, exact-pinned in both `pubspec.yaml` and `rust/Cargo.toml` — bump both together). Config is `flutter_rust_bridge.yaml` (`rust_input: crate::api`, `dart_output: lib/src/rust`). Every `pub` function/struct under `rust/src/api/**` becomes a generated Dart file under `lib/src/rust/api/`. After adding or changing a Rust API function, run `flutter_rust_bridge_codegen generate` — the generated Dart files (`lib/src/rust/**`) are committed source, not build output.

**Localization**: standard `flutter_localizations` + ARB setup (`l10n.yaml`). `lib/l10n/app_en.arb` is the template/source-of-truth locale; `app_ja.arb` (and any future locale) mirrors its keys. `generate: true` in `pubspec.yaml` means `flutter pub get` regenerates `lib/l10n/app_localizations*.dart` automatically. `MaterialApp.locale` in `lib/main.dart` (`_KeyChatAppState._locale`) is `null` by default (follow device locale) and gets overridden by the language picker on the login screen (`_LanguageSelector` in `lib/screens/login.dart`). **To add a language**: add `lib/l10n/app_<code>.arb` with the same keys, then add a display-name entry to the `_languageNames` map in `lib/screens/login.dart` — it's picked up automatically since the selector iterates `AppLocalizations.supportedLocales`.

**Screens flow**: `lib/main.dart` (`KeyChatApp`, stateful — owns locale state) -> `lib/screens/login.dart` (`ProfileSetupScreen`, collects display name + status message) -> on submit, calls the Rust `profile` API to persist, then navigates to `lib/screens/chat_list.dart` (`ChatListScreen`, currently a placeholder).

**Profile persistence**: `rust/src/api/profile.rs` (`save_profile`/`load_profile`) serializes a `Profile { display_name, status_message }` struct to `profile.json` (via `serde`/`serde_json`) inside a storage directory. The storage directory itself is resolved on the Dart side with `path_provider`'s `getApplicationDocumentsDirectory()` and passed in as a plain string — Rust doesn't know platform-specific paths itself.

**No fixed account key**: per the product direction, KeyChat has no persistent account keypair — key material (if any) is meant to be generated per-chat-peer, not stored as a single identity. Don't assume a global "current user" keypair exists anywhere; the only persisted per-device identity data is the display profile above. `rust/Cargo.toml` already depends on `nostr`/`nostr-database`/`nostr-lmdb` (NIP-17/44/59 features) for the eventual chat/event storage layer, but nothing in `lib/` or `rust/src/api/` wires that up yet.

**Stale generated boilerplate**: `test/widget_test.dart` and `integration_test/simple_test.dart` still reference the original `flutter create` template (a `MyApp` counter widget, and a `greet("Tom")` smoke test) that no longer matches the current app (`KeyChatApp` / `ProfileSetupScreen`). They will fail as-is — update or replace them rather than assuming they pass.
