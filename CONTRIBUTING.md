# Contributing

Thanks for considering a contribution to Recorder1.

Recorder1 is a macOS menu-bar recorder that handles private meeting audio. Contributions should keep reliability, privacy, and clear local-first behavior as the default.

## Before You Start

1. Read [README.md](README.md) or [README.zh-CN.md](README.zh-CN.md).
2. Read [PRIVACY.md](PRIVACY.md) before touching recording, upload, metadata, or logging behavior.
3. Read [SECURITY.md](SECURITY.md) before reporting security-sensitive issues.

## Development Setup

Requirements:

- macOS 15 or later.
- Xcode / Swift toolchain.
- Swift Package Manager.

Build:

```bash
swift build
./build.sh
```

Run:

```bash
open ./Recorder1.app
```

## Verification Before Opening A PR

Run:

```bash
swift build
./build.sh
bash scripts/verify-upload-retry.sh
bash scripts/verify-retention-cleanup.sh
```

If you changed audio capture behavior, also run the manual audio checks documented in the Verification section of [README.md](README.md).

## Privacy Rules

Do not commit:

- real recordings,
- `metadata.json` from real meetings,
- `upload.log` from real meetings,
- `feishu_minutes.json`,
- transcripts,
- summaries,
- Feishu tenant URLs,
- real `file_token`, `minute_token`, or `minute_url` values,
- signing certificates, private keys, or keychains.

Use fake values such as:

```text
fake-file-token
fake-minute-token
https://example.feishu.cn/minutes/fake-minute-token
```

## Pull Request Expectations

Each PR should include:

- a short explanation of the change,
- verification commands run,
- privacy impact if metadata, logs, upload, or recording behavior changed,
- screenshots only if UI changed and no private meeting data is visible.

## Code Style

- Prefer small, focused changes.
- Match the existing Swift style.
- Keep audio-thread code allocation-free and blocking-free.
- Do not introduce a network service owned by Recorder1.
- Do not add a second upload/transcription backend without a design discussion.

## License

By contributing, you agree that your contributions are released under the MIT License.
