# D-065B2 媒体预览开发现场

日期：2026-08-14

状态：开发中断存档，不可直接合并到 `main`，不可视为已构建或已验收。

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
