# D-065B2 媒体预览恢复与完成记录

日期：2026-08-14

状态：历史 checkpoint 已恢复；D-065B2-1 实现及主程自动化验收已完成，等待真机 + 真实 Alist 验收。

> 本文前半部分保留 2026-08-14 00:28 checkpoint 时的现场，便于追溯；“尚未完成”描述仅代表当时状态，不再代表当前代码。

## 已完成主线

- `main` 已推进到 `a8cd505`（`修复：服从最新视频播放意图`）。
- D-065B1a/B1b 的统一文件预览、固定 40pt 列表接线、Quick Look 和缓存失效已在主线完成。
- D-065B2-0 的视频 seek 播放意图修复已在主线完成。

## 本分支保存的半成品

- 从 `PlayerEngine.swift` 抽取原有严格 Range loader、媒体 URL 和 UTType 协商逻辑到 `Playback/MediaResourceLoaderBridge.swift`。
- 播放器已改为引用新的 bridge。
- bridge 已包含 4 MiB 单分片、可选累计已调度字节预算及 `invalidateAndWait()` API 骨架。

## 尚未完成及已知问题

- 当前 `invalidateAndWait()` 只等待 delegate queue 执行失效逻辑，尚不能证明已取消的分片 Task 真正返回。
- bridge 当前仍会异步关闭 session；后续 preview lease 也将拥有 session close，因此关闭所有权尚未收口。
- preview-only 累计预算最终决定为 16 MiB；当前 bridge 只提供参数，还没有 preview lease 以该值实例化。
- `PreviewMediaAssetLease`、视频代表帧、音频 embedded artwork、pipeline/UI 接线和工程文件接线均未实现。
- 新增 bridge 尚未接入 Xcode App target，因此本分支当前不保证编译。
- 未补媒体预览测试，未运行 build、test、Analyze、模拟器或真机验证。

## 固定续作契约

1. preview lease 唯一拥有 session 关闭，顺序固定为：取消 generator、取消 asset loading、等待 loader 全部终止、关闭 session。
2. preview loader 单片上限 4 MiB，累计已调度 Range 上限 16 MiB；失败、取消、重叠与重试均不退还预算。
3. 播放器继续使用无限累计配置，保留既有 fire-and-forget 停止路径和 session 关闭行为。
4. 视频只生成单张代表帧；音频只读取 embedded artwork。不得创建 `AVPlayer`/`AVPlayerItem`，不得激活 AVAudioSession、Now Playing 或后台播放。
5. 无 Range、无封面、不可解码、超预算或超时均诚实降级，不得完整下载大媒体或生成伪造海报/波形。
6. 媒体预览继续复用既有 pipeline 的 3 路并发、8 秒 deadline、waiter 合并/取消、来源 epoch 与 revision-aware 缓存。

## 恢复入口

- 源码仓库：`iosRemoteFolder`
- checkpoint 分支：`checkpoint/d065b2-media-preview-20260814`
- canonical 项目记录：`../Project/todolist/alist-media-player/`
- 受保护本地改动：`iosRemoteFolder.xcodeproj/xcshareddata/xcschemes/iosRemoteFolder.xcscheme` 不属于本分支，恢复开发时仍不得覆盖或提交。
- 恢复后先读取工作区根 `AGENTS.md` 及 canonical `README.md`、`decisions.md`、`todo.md`、`development.md`，再继续 D-065B2-1。

## 验证基线

- 半成品产生前的媒体播放器与预览专项基线为 18/18。
- B2-1 完成后必须由 Codex 主程重跑 `SessionMediaPlayerTests`、`ResourcePreviewPipelineTests`、完整测试、Simulator Debug build、Analyze、工程校验、敏感信息扫描与 iPhone UI/真机验收。

## 恢复后的最终实现（2026-08-14）

- `MediaResourceLoaderBridge` 已接入 App target，并由播放器与预览共用；播放器保持既有无限累计 Range 行为。
- preview-only `PreviewMediaAssetLease` 以 16 MiB 累计调度预算和 4 MiB 单分片上限工作，幂等关闭顺序为 generator -> asset -> loader -> session。
- 视频只生成一张真实代表帧；音频只读取 common、ID3 APIC、iTunes 与 QuickTime embedded artwork；无 Range、无封面、超预算或不可解码均返回明确降级。
- 列表已允许视频与音频进入统一预览管线；renderer version 升至 2，避免复用旧降级缓存。
- 未创建 `AVPlayer`/`AVPlayerItem`，未激活 `AVAudioSession`、Now Playing 或后台播放。

## 主程验证（2026-08-14）

- 完整 iPhone 17 Pro / iOS 26.5 模拟器测试：172/172 通过；其中 `ResourcePreviewPipelineTests` 17/17、`SessionMediaPlayerTests` 6/6。
- `xcodebuild analyze`、generic Simulator Debug build、工程 plist、diff 与敏感信息扫描作为最终提交门执行；结果以 canonical `Project/todolist/alist-media-player/development.md` 完成记录为准。
- 真机 + 真实 Alist 的封面命中率、弱网取消、滚动资源峰值与真实媒体交互仍属于运行态验收，不由 fixture 自动化替代。
