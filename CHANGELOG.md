# Changelog

## 0.2.0 - 2026-10-28

### Features
- Run on macOS 15 and later, with Apple on-device models available on eligible macOS 26+ systems.
- Simplified Chinese primary interface, activity descriptions and daily reviews.
- Explicit connection testing and manual retry controls for OpenAI-compatible Chat Completions services.

### Fixes
- Retry transient API failures up to three attempts; retain rule-based tracking during model failures.
- Recover failed activity descriptions after a cooldown and reject empty descriptions.
- Preserve existing Keychain entries if saving credentials fails.

### Distribution
- First release from the hi-unc1e fork, based on MIT-licensed tiann/weft.
- Apple Silicon build with ad-hoc signing; not Developer ID signed or notarized.
