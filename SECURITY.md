# Security Policy

Recorder1 handles meeting audio and metadata. Please treat security and privacy issues seriously.

## Supported Versions

Recorder1 is currently an MVP. Security fixes are accepted on the `main` branch.

## Reporting A Vulnerability

If you find a vulnerability, do not open a public issue with sensitive details.

Use a private disclosure channel if available on the GitHub repository. If private advisories are not enabled, open a minimal public issue that says a private security report is needed, without including:

- meeting audio,
- transcripts,
- Feishu tenant URLs,
- real tokens,
- local user paths,
- signing material,
- private logs.

## Sensitive Areas

Security-sensitive code paths include:

- `CLIProcessRunner.swift`
- `FeishuCLIUploader.swift`
- `FeishuMinutesParser.swift`
- `UploadStatusStore.swift`
- `SystemAudioTap.swift`
- `MicCapture.swift`
- recording cleanup and retention logic
- CI and release scripts

## Expected Security Properties

- Recorder1 does not embed Feishu tokens.
- Recorder1 uses the user's local `lark-cli` session.
- Recorder1 does not send data to a Recorder1-owned server.
- Upload logs and metadata are stored locally next to the recording.
- Upload failure must not delete local audio.
- Local cleanup must delete only uploaded recordings with a valid `minute_url`.

## Not In Scope

The following are generally outside this project's security scope:

- Feishu/Lark server behavior,
- `lark-cli` authentication internals,
- macOS TCC implementation bugs,
- user consent policy for meeting recording in a specific jurisdiction.

User consent and legal compliance remain the user's responsibility.
