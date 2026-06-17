---
name: Bug report
about: Report a reproducible Recorder1 bug
title: "[Bug]: "
labels: bug
assignees: ""
---

## Summary

Describe the bug in one or two sentences.

## Environment

- macOS version:
- Recorder1 commit or release:
- Output route: speaker / wired headset / Bluetooth headset / other
- Microphone input: system default / external USB / Bluetooth / other
- `lark-cli` installed: yes / no

## Steps To Reproduce

1.
2.
3.

## Expected Behavior

What should have happened?

## Actual Behavior

What happened instead?

## Verification Output

Paste non-sensitive output from relevant commands:

```bash
bash scripts/analyze-latest-audio.sh 1
```

## Logs And Privacy

Do not attach raw meeting recordings, real `metadata.json`, `upload.log`, `feishu_minutes.json`, transcripts, summaries, tenant URLs, or real tokens without redaction.

If a log is required, redact:

- meeting titles,
- local user paths,
- Feishu tenant domains,
- `file_token`,
- `minute_token`,
- `minute_url`,
- transcript text.

## Additional Context

Add screenshots only if they do not show private meeting data.
