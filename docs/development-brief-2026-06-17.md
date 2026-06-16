# Meeting Capture 开发简报 - 2026-06-17

## 结论

Meeting Capture 的 MVP 主链路已经完成：菜单栏应用可启动，Gemini 已移除，Feishu CLI 上传链路已接入并通过真实上传验证，MainQuest 黑色版菜单栏 UI 已完成。

当前唯一阻塞是系统输出音频采样：Core Audio Tap 有回调、有帧数，但 macOS 返回的样本全为 0。因此 `audio.m4a` 目前可以包含麦克风声音，也可以被飞书妙记接受，但还不能证明已经包含远端会议声音。

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

## 当前阻塞

系统输出音频仍为空样本。

最终诊断命令：

```bash
MeetingCapture.app/Contents/MacOS/Recorder --diagnose-system-audio --diagnose-output /tmp/meeting-capture-system-audio-final.json
```

诊断结果：

```json
{
  "frameCount": 260096,
  "ok": false,
  "peakDB": -120,
  "rmsDB": -120,
  "sampleRate": 48000
}
```

解释：

- `frameCount` 有值，说明 Core Audio 回调正常。
- `rmsDB=-120` 和 `peakDB=-120`，说明 macOS 交给应用的系统音频样本全为 0。
- 代码侧已尝试从全局 Tap 切到默认输出设备绑定 Tap，结果仍为空。
- 当前高概率原因是 macOS 26 的签名 / TCC 信任链限制：系统设置里显示已授权，但 Core Audio Tap 仍可能返回空样本。

## 不建议继续反复做的事

- 不建议反复 `tccutil reset`。
- 不建议反复弹系统权限和钥匙串确认。
- 不建议在用户无人值守时强行信任自签证书。

这些动作会制造新的权限噪音，并且用户已经明确反馈不希望反复输入密码或点确认。

## 建议下一步

1. 做一次稳定签名收口。
   - 使用受信任的 Apple Development / Developer ID 证书签名。
   - 或者由用户明确确认一次本地证书信任。
   - 签名稳定后重新触发系统音频授权。

2. 重新跑系统音频诊断。
   - 目标结果：`ok=true`，`rmsDB` 明显高于 `-80dB`。

3. 做真实会议验收。
   - Zoom
   - 飞书会议
   - 腾讯会议
   - Teams
   - Google Meet

4. 做设备路由验收。
   - 外放
   - 有线耳机
   - AirPods / 蓝牙耳机

5. 做 30 分钟连续录制。
   - 验收命令：

```bash
bash scripts/analyze-latest-audio.sh 1800
```

## 当前产品状态

产品主体可以继续迭代和演示 Feishu 上传链路；完整会议录音验收仍卡在系统输出音频进入 `audio.m4a` 这一项。
