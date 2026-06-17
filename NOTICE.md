# Notice

Recorder1 is derived from [tobi/recorder](https://github.com/tobi/recorder), originally created by Tobias Lütke and released under the MIT License.

The original MIT license notice is preserved in [LICENSE](LICENSE).

## Major Modifications

Recorder1 keeps the upstream macOS menu-bar recording foundation and adds a Feishu Minutes workflow:

- Renamed the product to Recorder1.
- Replaced Gemini transcription with `lark-cli` based Feishu upload.
- Added Feishu Drive upload, Feishu Minutes creation, optional notes fetching, retry, local logs, and metadata.
- Added audio quality analysis and degraded-capture upload protection.
- Added system-audio diagnostics and signed acceptance build scripts.
- Added microphone input device selection for external and Bluetooth microphones.
- Added Chinese/English UI text.
- Added uploaded-recording retention cleanup.
- Changed the local recording folder to `~/Documents/Recorder1`.

## Upstream Project

- Upstream repository: <https://github.com/tobi/recorder>
- License: MIT
- Original copyright: Copyright (c) 2026 Tobias Lütke

## Recorder1 Contributions

- Recorder1 modifications copyright holder: Copyright (c) 2026 Dingcheng and Recorder1 contributors.
- Recorder1-specific changes are released under the same MIT License unless a file states otherwise.
