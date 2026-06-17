# Recorder1 中文说明

Recorder1 是一个原生 macOS 菜单栏会议录音工具，用来录制会议音频，并通过本机 `lark-cli` 把录音上传到飞书妙记。

它会同时录制两路声音：

- **系统声音 -> 左声道**：你从扬声器、耳机或会议软件里听到的远端声音。
- **麦克风 -> 右声道**：你的本机麦克风、外接 USB 麦克风或蓝牙麦克风。

录制结束后，Recorder1 会保留原始音轨文件，生成一个立体声 `audio.m4a`，上传到飞书云空间，再创建飞书妙记，并把本地元数据和上传日志保存在同一个录音目录里。

## 当前状态

Recorder1 当前是 MVP 阶段。核心链路已经完成：菜单栏录音、双声道混音、飞书上传、妙记生成、上传失败重试、元数据保存和本地清理策略。

建议在正式依赖前完成这些验收：

- 至少一次真实会议软件录制。
- 至少一次蓝牙耳机输出 + 外接麦克风输入录制。
- 至少一次外放或有线耳机录制。
- 至少一次 30 分钟连续录制。

## 和上游 Recorder 的关系

Recorder1 基于 [tobi/recorder](https://github.com/tobi/recorder) 改造。上游项目提供了非常关键的本地录音基础：

- 原生 macOS menu-bar app。
- Swift / SwiftUI 实现。
- 系统声音与麦克风双源采集。
- `desktop.caf`、`mic.caf` 和 `audio.m4a` 输出。
- Calendar、Notification、Recordings Library 等模块。

Recorder1 保留这些本地录音能力，把录音后的处理链路从 Gemini 转写改成飞书妙记上传。

详细改造说明见：[docs/upstream-recorder-migration.md](docs/upstream-recorder-migration.md)。

## 主要功能

- 菜单栏一键开始 / 停止录音，无 Dock 图标。
- 同时录制系统输出声音和麦克风输入声音。
- 输出立体声 `audio.m4a`，左声道为系统声音，右声道为麦克风。
- 支持指定麦克风输入设备，适合外接 USB 麦克风、蓝牙麦克风等场景。
- 读取日历会议，用会议标题命名录音目录。
- 飞书上传流程：
  - `lark-cli drive +upload`
  - `lark-cli minutes +upload`
  - 可选 `lark-cli vc +notes`
- 上传失败后保留本地录音，可直接 Retry Upload。
- 保存 `metadata.json`、`upload.log`、`feishu_minutes.json`、`transcript.md` 和 `summary.md`。
- 混音后自动分析音频质量。
- 如果只录到麦克风、系统声音为空，默认阻止自动上传，并提示用户确认。
- 输出设备变化时记录日志，并重建系统音频采集链路。
- UI 支持中文和英文切换。
- 支持上传成功后自动清理本地录音：永久保留、15 天后删除、30 天后删除。

## 本地文件结构

录音保存在：

```text
~/Documents/Recorder1/{YYYY-MM-DD_HHmm}-{meeting-title}/
  desktop.caf
  mic.caf
  audio.m4a
  metadata.json
  upload.log
  feishu_minutes.json
  transcript.md
  summary.md
```

文件说明：

| 文件 | 作用 |
| --- | --- |
| `desktop.caf` | 原始系统声音，录制过程中持续写入。 |
| `mic.caf` | 原始麦克风声音，录制过程中持续写入。 |
| `audio.m4a` | 最终立体声文件，左声道为系统声音，右声道为麦克风。 |
| `metadata.json` | 会议信息、本地路径、上传状态、飞书 token、音频质量、采集完整性和麦克风设备信息。 |
| `upload.log` | 本地上传和采集日志。 |
| `feishu_minutes.json` | 飞书云空间、飞书妙记和纪要接口返回结果。 |
| `transcript.md` | 飞书返回逐字稿时生成。 |
| `summary.md` | 飞书返回摘要时生成。 |

## 环境要求

- macOS 15 或更高版本。
- 可编译 Swift Package Manager 项目的 Xcode / Swift 工具链。
- 已安装并登录 `lark-cli`。
- 当前 Feishu/Lark 用户需要具备这些权限：
  - `drive:file:upload`
  - `minutes:minutes.upload:write`
  - `vc:note:read`
  - `minutes:minutes:readonly`
  - `minutes:minutes.artifacts:read`
  - `minutes:minutes.transcript:export`

Recorder1 会自动从常见 Homebrew/npm 路径和 `PATH` 中查找 `lark-cli`。也可以在设置里指定 `lark-cli` 路径。

## 构建

```bash
./build.sh
open ./Recorder1.app
```

默认构建会使用 ad-hoc 签名，方便本地无人值守构建。正式验收建议使用稳定签名身份：

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" ./build.sh
```

如果证书在独立钥匙串里：

```bash
CODESIGN_IDENTITY="Developer ID Application: Example" \
CODESIGN_KEYCHAIN="/path/to/signing.keychain-db" \
./build.sh
```

稳定签名很重要。macOS 会把麦克风、系统音频、日历和文件夹权限绑定到 App 身份。频繁 ad-hoc 构建可能导致重复授权，部分 macOS 26 环境还可能出现系统音频回调有数据帧但样本全为 0 的情况。

严格系统音频验收构建：

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" \
bash scripts/build-for-audio-capture-acceptance.sh
```

这个脚本会拒绝 ad-hoc 签名，并写出 `signing-report.txt`。

## 本机安装

构建完成后，把 App 安装到应用程序目录：

```bash
rm -rf /Applications/Recorder1.app
ditto --rsrc --extattr Recorder1.app /Applications/Recorder1.app
open /Applications/Recorder1.app
```

Recorder1 是菜单栏应用。启动后请在 macOS 菜单栏里找麦克风图标。

## 首次授权

Recorder1 会向 macOS 申请这些权限：

| 权限 | 用途 |
| --- | --- |
| 麦克风 | 录制本地麦克风声音。 |
| 系统音频录制 | 通过 Core Audio Tap 录制会议软件或系统输出声音。 |
| 日历 | 读取附近会议，用会议标题命名录音。 |
| 通知 | 会议结束时提醒仍在录制。 |
| 文稿文件夹 | 把录音保存到 `~/Documents/Recorder1`。 |

如果改过 bundle id 或签名身份后权限状态异常，可以重置权限后重新打开：

```bash
tccutil reset All com.dingcheng.Recorder1
open /Applications/Recorder1.app
```

## 设置项

Recorder1 当前支持这些设置：

- `lark-cli` binary path：手动指定 `lark-cli` 路径。
- Auto upload after save：保存后自动上传。
- Fetch notes after upload：创建妙记后拉取纪要和逐字稿。
- Copy minute URL after upload：上传完成后复制妙记链接。
- Open minute URL after upload：上传完成后打开妙记链接。
- Language：中文 / English。
- Microphone input：跟随系统默认输入，或固定使用某个外接 / 蓝牙麦克风。
- Local retention：上传成功后本地录音保留策略。
- Silence auto-stop：长时间静音后自动停止录音。

## 飞书 CLI 流程

```text
audio.m4a
  -> lark-cli drive +upload --as user --file audio.m4a --json
  -> file_token
  -> lark-cli minutes +upload --as user --file-token <file_token> --json
  -> minute_url
  -> minute_token
  -> lark-cli vc +notes --as user --minute-tokens <minute_token> --overwrite --json
```

飞书妙记生成是异步流程。如果 `vc +notes` 返回妙记尚未准备好，Recorder1 会短时间重试。

上传失败不会删除本地录音。错误会写入 `upload.log`，`audio.m4a` 会保留，用户可以在菜单栏里 Retry Upload。

## 验证

运行 MVP 自检：

```bash
bash scripts/verify-mvp.sh
```

这个脚本会检查本地 macOS/Xcode/Swift 环境、构建结果、菜单栏配置、Feishu CLI 表面、上传失败重试、最新录音目录和 `audio.m4a` 可播放性。

真实会议或设备路由测试后，分析最新录音：

```bash
bash scripts/analyze-latest-audio.sh 1
```

30 分钟验收：

```bash
bash scripts/analyze-latest-audio.sh 1800
```

严格声道验收要求左右声道都存在可测量声音。混音文件里左声道是系统声音，右声道是麦克风。

系统音频矩阵诊断：

```bash
Recorder1.app/Contents/MacOS/Recorder \
  --diagnose-system-audio-matrix \
  --diagnose-output /tmp/recorder1-system-audio-matrix.json
```

严格本地音频采集验收：

```bash
bash scripts/verify-audio-capture-acceptance.sh
```

如果 App 是 ad-hoc 签名、没有任何 default output probe 通过、`desktop.caf` 静音，或 `audio.m4a` 左声道静音，脚本会失败。

## 架构

```text
MenuBarExtra / RecorderPanel
        |
        v
RecorderModel
  |         |
  |         +--> MicCapture -> mic.caf
  |
  +------------> SystemAudioTap -> desktop.caf
                    |
                    v
             StereoMixer -> audio.m4a
                    |
                    v
          AudioQualityAnalyzer
                    |
                    v
             FeishuCLIUploader
                    |
                    v
  metadata.json / upload.log / feishu_minutes.json / transcript.md / summary.md
```

核心文件：

| 文件 | 作用 |
| --- | --- |
| `RecorderApp.swift` | 菜单栏 App 入口和诊断命令路由。 |
| `RecorderModel.swift` | 录音、混音、上传、重试和清理的主状态机。 |
| `RecorderPanel.swift` | 菜单栏 UI。 |
| `SystemAudioTap.swift` | 系统声音采集、fallback、路由变化处理和采集元数据。 |
| `MicCapture.swift` | 麦克风采集和输入设备选择。 |
| `StereoMixer.swift` | 对齐原始音轨并输出立体声 AAC。 |
| `FeishuCLIUploader.swift` | 执行 Feishu `lark-cli` 上传链路。 |
| `FeishuMinutesParser.swift` | 解析 CLI JSON 并提取飞书妙记产物。 |
| `UploadStatusStore.swift` | 写入元数据和上传日志。 |
| `RecordingCleanup.swift` | 按保留策略清理已上传录音。 |

## 常见问题

### 没有弹出麦克风权限

检查安装包签名和 entitlement：

```bash
codesign -dv --verbose=4 /Applications/Recorder1.app
codesign --display --entitlements :- /Applications/Recorder1.app
```

然后重置权限并重新打开：

```bash
tccutil reset All com.dingcheng.Recorder1
open /Applications/Recorder1.app
```

### 系统声音是静音

用安装后的 App 身份运行矩阵诊断：

```bash
/Applications/Recorder1.app/Contents/MacOS/Recorder \
  --diagnose-system-audio-matrix \
  --diagnose-output /tmp/recorder1-system-audio-matrix.json
```

部分 macOS 26 环境里，global tap 和 device-bound tap 可能返回静音样本，process mixdown 可用。Recorder1 会把实际 tap 模式写入 `metadata.json`。

### 上传失败

先看本地目录里的：

```text
upload.log
metadata.json
```

修复 `lark-cli` 登录、路径或权限后，在菜单栏里点击 Retry Upload。

## 文档

- 英文首页：[README.md](README.md)
- 上游改造说明：[docs/upstream-recorder-migration.md](docs/upstream-recorder-migration.md)
- 开发简报：[docs/development-brief-2026-06-17.md](docs/development-brief-2026-06-17.md)
- 验证记录：[docs/verification-2026-06-16.md](docs/verification-2026-06-16.md)
- 研究笔记：[docs/research-notes.md](docs/research-notes.md)

## 隐私说明

Recorder1 会把录音和元数据保存在 `~/Documents/Recorder1`。如果开启自动上传，`audio.m4a` 会通过当前用户本机的 `lark-cli` 会话上传。App 本身不内置飞书凭据或 API token。

`metadata.json` 和 `upload.log` 可能包含会议标题、本地路径、飞书文件 token 和妙记链接。请把录音目录视为私有数据。

## 许可证

MIT。见 [LICENSE](LICENSE)。

Recorder1 基于 [tobi/recorder](https://github.com/tobi/recorder) 改造。来源和改造说明见 [NOTICE.md](NOTICE.md)。
