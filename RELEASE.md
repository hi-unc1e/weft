# Weft 0.2.0

Native macOS time tracking with rules, Apple on-device AI, or a user-configured OpenAI-compatible Chat Completions endpoint.

## Install

Download `Weft-0.2.0-arm64.zip` from [GitHub Releases](https://github.com/hi-unc1e/weft/releases/tag/v0.2.0), extract it and move Weft.app to Applications. Requires an Apple Silicon Mac running macOS 15+.

This fork build is **ad-hoc signed and not notarized**. macOS may block a downloaded copy under Gatekeeper. There is no Developer ID trust guarantee; you may prefer building from source. No system-wide security changes are required by the app.

## Configure a model

Open Settings → 模型, select OpenAI 兼容接口, enter the provider's Base URL, exact model ID and API key, then select 保存并连接. A typical Base URL is `https://api.openai.com/v1`; local Ollama/LM Studio servers may not require a key. Use a model that supports Chat Completions with text responses.

Keys are stored in macOS Keychain. When a remote endpoint is enabled, relevant app names, domains, window titles, work-stream context and daily statistics are sent to that endpoint. Configure exclusions and title/domain privacy controls before use. With no model configured, rules and manual classification continue to work. Apple on-device AI requires macOS 26+ and an available Apple Intelligence model.

## Validation

The release process runs the Swift Testing suite, builds the Release app, verifies its ad-hoc signature, embeds its source commit, scans the published source and application for secrets and local account paths, and publishes checksums.

Real provider inference, Apple on-device inference, long-running battery behavior and every browser/permission combination require separate runtime acceptance. Automated network tests use simulated responses.

## Build

Requires Xcode 26.1+ and XcodeGen. From a clean checkout, run `bash scripts/release-local.sh`. This builds only committed sources in a temporary directory, without copying Keychain entries, preferences, runtime databases, private signing configuration or local reports. Output is in `build/release/`. The original `scripts/release.sh` remains available for users with their own Developer ID and notarization setup.

This fork retains the upstream MIT license and copyright.
