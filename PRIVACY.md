# Privacy

Recorder1 records meeting audio. Treat all recording folders as sensitive.

## Where Local Data Is Stored

Recorder1 writes recordings under:

```text
~/Documents/Recorder1/{YYYY-MM-DD_HHmm}-{meeting-title}/
```

A recording folder can contain:

```text
desktop.caf
mic.caf
audio.m4a
metadata.json
upload.log
feishu_minutes.json
transcript.md
summary.md
minutes/
```

## When Audio Is Uploaded

Recorder1 uploads `audio.m4a` only when upload is enabled or when the user manually retries or confirms upload.

The upload flow is:

1. Upload `audio.m4a` to Feishu Drive.
2. Create a Feishu Minute from the Drive file.
3. Optionally fetch Feishu Minutes notes and artifacts.

If capture integrity detects that system audio is missing while microphone audio is present, Recorder1 can block automatic upload and ask the user to confirm.

## Which Credentials Are Used

Recorder1 uses the user's own local `lark-cli` session.

Recorder1 does not:

- embed a Feishu token,
- store a Feishu password,
- run a Recorder1-hosted backend,
- send recordings to a Recorder1-owned server.

## Sensitive Local Files

These files can contain sensitive meeting information:

- `metadata.json`
- `upload.log`
- `feishu_minutes.json`
- `transcript.md`
- `summary.md`
- files under `minutes/`

They may include:

- meeting titles,
- local file paths,
- selected microphone and audio route metadata,
- Feishu file tokens,
- Feishu Minute URLs,
- transcript or summary content,
- upload errors and CLI output snippets.

Do not attach these files to public GitHub issues without reviewing and redacting them.

## Local Cleanup

Recorder1 can delete local recording folders after a successful Feishu Minutes upload.

Available policies:

- keep forever,
- delete after 15 days,
- delete after 30 days.

Cleanup only deletes folders whose metadata indicates `upload_status=uploaded` and includes a non-empty `minute_url`.

## User Responsibility

Users are responsible for:

- complying with meeting recording laws,
- obtaining required participant consent,
- confirming that Feishu/Lark upload is allowed in their organization,
- managing retention and deletion of local and cloud copies,
- redacting sensitive logs before sharing bug reports.
