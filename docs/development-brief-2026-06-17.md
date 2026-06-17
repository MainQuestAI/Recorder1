# Meeting Capture 开发简报 - 2026-06-17

## 结论

Meeting Capture 的 MVP 主链路已经完成：菜单栏应用可启动，Gemini 已移除，Feishu CLI 上传链路已接入并通过真实上传验证，MainQuest 黑色版菜单栏 UI 已完成。

系统输出音频全 0 的根因已收窄并完成工程兜底：当前机器上 global tap / device-bound tap 会返回全 0，但同一签名 app 下的 process mixdown tap 可以拿到非零系统音频。生产录音现在按 `global -> device_bound -> process_mixdown` 自动降级，并且本地音频验收已证明 `desktop.caf` 和 `audio.m4a` 左声道都有系统输出音频。

## 已完成范围

- 应用形态：macOS 菜单栏应用，`LSUIElement=true`，无 Dock 图标。
- 录音文件结构：
  - `desktop.caf`
  - `mic.caf`
  - `audio.m4a`
  - `metadata.json`
  - `upload.log`
  - `feishu_minutes.json`
  - `transcript.md`
  - `summary.md`
- Feishu CLI 链路：
  - `drive +upload` 提取 `file_token`
  - `minutes +upload` 提取 `minute_url`
  - 从 `minute_url` 提取 `minute_token`
  - `vc +notes` 获取妙记内容并写本地文件
- 上传失败保护：
  - 本地 `audio.m4a` 不删除
  - `upload.log` 记录错误
  - `Retry Upload` 复用已生成的 `audio.m4a`
- 元数据：
  - 会议标题、开始时间、结束时间、本地路径
  - `file_token`、`minute_url`、`minute_token`
  - 上传状态
  - `audio_quality` 声道质量分析
- UI：
  - 菜单栏面板已改为 MainQuest Dark Glass 风格
  - 黑底、玻璃卡片、白灰文字、状态色收敛
  - 保留 Record / Stop / Retry Upload / Open Minute / Copy URL 等核心动作

## 已验证结果

- 本机环境：
  - macOS `26.5.1`
  - Xcode `26.5`
  - Swift `6.3.2`
- `bash scripts/verify-mvp.sh`：
  - `26 passed`
  - `3 warnings`
  - `0 failed`
- Feishu：
  - `lark-cli` 已安装并登录
  - 必要权限已验证
  - 真实上传已成功拿到 `file_token`
  - 真实生成妙记已成功拿到 `minute_url`
  - `vc +notes` 已成功返回转写文件
- 系统音频验收：
  - 签名验收构建不是 ad-hoc
  - `--diagnose-system-audio-matrix` 中 `process_afplay` / `process_running_mixdown` / `process_all_mixdown` 均为 `ok=true`
  - `--diagnose-audio-capture-acceptance` 通过
  - `desktop.caf` RMS 约 `-15.5dB`
  - `audio.m4a` 左声道 RMS 约 `-15.5dB`

## 系统音频诊断结论

最终诊断命令：

```bash
MeetingCapture.app/Contents/MacOS/Recorder --diagnose-system-audio-matrix --diagnose-output /tmp/meeting-capture-system-audio-matrix.json
```

核心结果：

- `global` tap：回调和帧数正常，但样本仍为 `-120dB`。
- `device_bound` tap：回调和帧数正常，但样本仍为 `-120dB`。
- `process_afplay`：`ok=true`，RMS 约 `-15dB`。
- `process_running_mixdown`：`ok=true`，RMS 约 `-15dB`。
- `process_all_mixdown`：`ok=true`，RMS 约 `-15dB`。

解释：

- 签名 / TCC / Core Audio Tap 基础权限已经成立。
- 设备选择不是主因，`defaultOutputDevice` 和 `defaultSystemOutputDevice` 在本机测试中可相同，也都能进入进程级 tap。
- 当前 macOS 26 环境下，系统级 global / device-bound 混音路径会给空样本；进程级 mixdown 路径可用。
- 因此生产录音保留 global 优先，但如果静音会自动切到 device-bound，再切到 process mixdown。

录音验收命令：

```bash
MeetingCapture.app/Contents/MacOS/Recorder --diagnose-audio-capture-acceptance --diagnose-output /tmp/meeting-capture-audio-capture-acceptance.json
```

验收结果：

```json
{
  "ok": true,
  "rmsDB": -15.455,
  "peakDB": -12.041,
  "audioLeftRMSDB": -15.462,
  "audioLeftPeakDB": -11.852,
  "sampleRate": 48000
}
```

## 不建议继续反复做的事

- 不建议反复 `tccutil reset`。
- 不建议反复弹系统权限和钥匙串确认。
- 不建议在用户无人值守时强行信任自签证书。

这些动作会制造新的权限噪音，并且用户已经明确反馈不希望反复输入密码或点确认。

## 建议下一步

1. 做真实会议验收。
   - Zoom
   - 飞书会议
   - 腾讯会议
   - Teams
   - Google Meet

2. 做设备路由验收。
   - 外放
   - 有线耳机
   - AirPods / 蓝牙耳机

3. 做 30 分钟连续录制。
   - 验收命令：

```bash
bash scripts/analyze-latest-audio.sh 1800
```

## 当前产品状态

产品主体可以继续迭代和演示 Feishu 上传链路；本地系统音频已经能进入 `desktop.caf` 和 `audio.m4a` 左声道。剩余验收是会议软件、耳机/外放路由和 30 分钟连续录制。
