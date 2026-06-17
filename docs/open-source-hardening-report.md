# Open Source Hardening Report

This report records the pre-publication hardening pass for Recorder1.

## Scope

The hardening pass covered:

- public documentation cleanup,
- upstream license and attribution,
- privacy and security documentation,
- GitHub issue and PR templates,
- CI workflow,
- `.gitignore` hardening,
- sensitive information scanning,
- naming consistency review.

## Documentation Cleanup

Public README links now point only to public-safe documents:

- `README.md`
- `README.zh-CN.md`
- `NOTICE.md`
- `COPYRIGHT.md`
- `PRIVACY.md`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `docs/upstream-recorder-migration.md`
- `docs/release-validation.md`
- `docs/verification-2026-06-16.md`

The former internal research notebook was replaced with:

- `docs/internal-research-notes.redacted.md`

It is no longer linked from the README because the original notebook contained exploratory notes, outdated `.ogg` / ffmpeg options, local environment observations, and internal decision language.

## License And Attribution

- `LICENSE` preserves the upstream MIT license notice.
- `NOTICE.md` identifies the upstream project and the Recorder1 modifications.
- `COPYRIGHT.md` separates upstream copyright from Recorder1 modification copyright.

## Privacy And Security Files

Added:

- `PRIVACY.md`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `.github/ISSUE_TEMPLATE/bug_report.md`
- `.github/ISSUE_TEMPLATE/feature_request.md`
- `.github/pull_request_template.md`

Privacy coverage includes:

- where local recordings are stored,
- when uploads happen,
- use of the user's own `lark-cli` session,
- no embedded Feishu token,
- no Recorder1-owned server,
- sensitive local metadata/log files,
- user responsibility for meeting recording consent and compliance.

## CI Boundary

Added:

- `.github/workflows/ci.yml`

CI runs on `macos-latest` and covers:

- checkout,
- `swift build`,
- `./build.sh`,
- `codesign --verify --deep --strict Recorder1.app`,
- `bash scripts/verify-upload-retry.sh`,
- `bash scripts/verify-retention-cleanup.sh`.

CI intentionally does not:

- request TCC permissions,
- capture real system audio,
- require a logged-in `lark-cli`,
- upload to a real Feishu tenant.

## Sensitive Information Scan

Command used:

```bash
rg -n "file_token|minute_url|minute_token|feishu.cn/minutes|l2juegzht0|/Users/dingcheng|CODESIGN_KEYCHAIN|Apple Development|Developer ID Application|private key|api key|GEMINI|OPENAI" .
```

Result:

- No real Feishu tenant domain was found.
- No real `file_token`, `minute_token`, or `minute_url` was found.
- No private local user path was found outside the required scan command text.
- No OpenAI key, Gemini key, private key, signing certificate, or keychain file was found.

Allowed matches:

- `file_token`, `minute_url`, and `minute_token` appear as Feishu API field names.
- `fake-file-token`, `fake-minute-token`, and `https://example.feishu.cn/minutes/fake-minute-token` appear in tests and docs as fake examples.
- `CODESIGN_KEYCHAIN` appears as an environment variable name for local signing configuration.
- `/Users/dingcheng`, `Apple Development`, and `Developer ID Application` appear only inside the required scan command text above.
- `private key` appears only in contribution/security policy text that tells contributors not to commit signing keys.
- `Gemini` appears only to describe the upstream feature that Recorder1 removed or to verify that the old source module is absent.

Additional added-line redaction check:

- Public-repository redaction scan on added lines returned no findings.

## Naming Consistency Review

Current names:

| Surface | Current value |
| --- | --- |
| Repository | `Recorder-One` |
| App name | `Recorder1` |
| App bundle | `Recorder1.app` |
| Swift package | `Recorder` |
| Executable | `Recorder` |
| Bundle ID | `com.dingcheng.Recorder1` |

Recommendation for public release:

- Keep `Recorder-One` as the GitHub repository name. It is readable and already published privately.
- Keep `Recorder1` as the app name for the current MVP to avoid another macOS TCC permission reset.
- Keep the Swift package and executable as `Recorder` for now because they are inherited from upstream and are not user-facing.
- Consider a future breaking rename to `RecorderOne` / `recorder-one` / `com.mainquest.recorderone` only when preparing a packaged public release.

Important migration note:

Changing `CFBundleIdentifier` from `com.dingcheng.Recorder1` to another bundle ID will cause macOS to treat the app as a new privacy identity. Users will need to grant microphone, system audio, calendar, and file permissions again.
