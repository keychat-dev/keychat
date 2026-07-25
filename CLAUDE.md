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

**Platform scope**: only Android (and eventually iOS) is actively developed/tested. Web/Windows/Linux desktop builds exist as scaffolding but are not maintained or verified — don't assume they work.

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

# Regenerate launcher icons after changing assets/branding/app_icon.png
dart run flutter_launcher_icons
```

Rust itself is never built with `cargo build` directly — `flutter run`/`flutter build` invoke it through the Native Assets build hook (`hook/build.dart`), which drives `flutter_rust_bridge_hooks` against `rust/` (no `cargokit`). To just typecheck Rust changes without a full Flutter rebuild, `cargo check --lib` from `rust/` works and is much faster.

## Git workflow

Commit in focused, single-purpose commits rather than bundling unrelated changes — split by nature of change (new feature / rename-refactor / visual tweak / bug fix) so `git log` and `git blame` stay useful. Don't let unrelated changes pile up into one large commit.

## Architecture

**Split**: Flutter (`lib/`) owns UI only — screen layout, input, calling into Rust, displaying results. Rust (`rust/src/`) owns all key management, protocol logic, and storage/DB operations. Don't put persistence or crypto logic in Dart.

**Exception — OS secure storage**: platform Keystore/Keychain (accessed via `flutter_secure_storage`) has no filesystem path Dart can hand to Rust the way it does for `path_provider` directories — it's only reachable through the Flutter plugin's platform channel. For secrets backed by secure storage (e.g. the account seed phrase), Dart is allowed to perform the raw read/write/delete calls against `flutter_secure_storage` directly, but all decision logic (generating, validating, deriving, encrypting) must still live in Rust and be called through the bridge — Dart's role there is limited to "pass the opaque string to/from the OS," never business logic.

**Flutter <-> Rust bridge**: `flutter_rust_bridge` (pinned to `2.13.0-beta.4`, exact-pinned in both `pubspec.yaml` and `rust/Cargo.toml` — bump both together). Config is `flutter_rust_bridge.yaml` (`rust_input: crate::api`, `dart_output: lib/src/rust`). Every `pub` function/struct under `rust/src/api/**` becomes a generated Dart file under `lib/src/rust/api/`. After adding or changing a Rust API function, run `flutter_rust_bridge_codegen generate` — the generated Dart files (`lib/src/rust/**`) are committed source, not build output.

**Localization**: standard `flutter_localizations` + ARB setup (`l10n.yaml`). `lib/l10n/app_en.arb` is the template/source-of-truth locale; `app_ja.arb` mirrors its keys. `generate: true` in `pubspec.yaml` means `flutter pub get` regenerates `lib/l10n/app_localizations*.dart` automatically. `MaterialApp.locale` in `lib/main.dart` (`_KeyChatAppState._locale`) is `null` by default (follow device locale) and gets overridden by the language picker. **To add a language**: add `lib/l10n/app_<code>.arb` with the same keys, then add a display-name entry to the shared `languageNames` map in `lib/languages.dart` — both the auth-choice screen's language selector and Settings' language picker read from it automatically.

**Screens flow**: `lib/main.dart` (`KeyChatApp`, stateful — owns locale state, and the top-level navigation callbacks: `_logout`, `_handleContinue`) is the root. First launch (no persisted `Account`) shows `lib/screens/auth_choice.dart` (`AuthChoiceScreen`): choose "Sign up" (goes to `lib/screens/login.dart`'s `ProfileSetupScreen` to collect display name/status/avatar) or "Log in" (currently a visual-only placeholder for restoring from a seed phrase — not wired to real restore logic yet). Signing up flows: profile setup -> `lib/screens/relay_settings.dart` (relay list, seeded with defaults) -> `lib/screens/setup_complete.dart` (animated confirmation) -> `lib/screens/home.dart` (`HomeScreen`, bottom-nav shell: Home/Talk/Public Chat tabs, top-right bell/add-friend/settings icons). Logging out wipes local Account/relay/seed data and returns to `AuthChoiceScreen`.

**Home tab contents**: `lib/screens/account_friends.dart` (`AccountFriendsTab`) shows the local account card (avatar/name/status, edit button -> `lib/screens/edit_profile.dart`) plus a friends list (currently always empty — QR-based add-friend is UI-only, not wired up). `lib/screens/chat_list.dart` and `lib/screens/public_chat_list.dart` back the other two tabs and are placeholders.

**Settings**: `lib/screens/settings.dart` links to Profile edit, Relay settings, Language picker, and Account (`lib/screens/logout.dart`'s `AccountSettingsScreen`) — which offers seed-phrase backup and logout.

**Account (display identity) persistence**: `rust/src/api/account.rs` (`save_account`/`load_account`) serializes an `Account { display_name, status_message, avatar_path }` struct to `account.json` via `serde`/`serde_json`, inside a storage directory Dart resolves with `path_provider`'s `getApplicationDocumentsDirectory()` and passes in as a plain string.

**Relay list persistence**: `rust/src/api/relay.rs` — `save_relay_list`/`load_relay_list` persist to `relays.json` the same way; `check_relay_statuses` opens short-lived WebSocket connections (via `tokio-tungstenite`) to report per-relay reachability. A `rustls` crypto provider is installed once at startup in `rust/src/api/simple.rs`'s `#[frb(init)] init_app()` — required before any `wss://` connection works.

**Account seed / key material**: `rust/src/api/keys.rs` has pure, I/O-free crypto logic — `generate_mnemonic()` (12-word BIP-39 phrase) and `validate_mnemonic()` (checks it's a valid BIP-39 phrase AND can derive Nostr keys per NIP-06). Persistence of the seed phrase happens in Dart via `flutter_secure_storage` (OS Keystore/Keychain — see the architecture exception above), keyed by `seedStorageKey` (exported from `lib/screens/logout.dart`). There is no fixed, network-visible account key: the seed is purely local-device material for now. Longer-term direction (not yet implemented): NIP-49-style passphrase encryption of the seed for cross-device sync via relays, kept separate from the Keystore-backed local copy since Keystore keys are device-bound and can't be exported for that purpose. `rust/Cargo.toml` depends on `nostr` (with `nip06`, `nip44`, `nip49`, `nip59` features), `nostr-database`, `nostr-lmdb`, and `bip39` for this and the eventual chat/event storage layer, but chat itself isn't wired up yet.

**Stale generated boilerplate**: `test/widget_test.dart` and `integration_test/simple_test.dart` still reference the original `flutter create` template (a `MyApp` counter widget, and a `greet("Tom")` smoke test) that no longer matches the current app. They will fail as-is — update or replace them rather than assuming they pass.
