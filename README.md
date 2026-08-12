# iosRemoteFolder

> **项目状态：已恢复开发（2026-08-13）。** 项目曾于 2026-08-11 暂停并保存为技术实验快照（见 [项目复盘](docs/retrospective-2026-08.md)）。恢复依据：项目所有者在暂停期间长期实际使用成熟替代品（ES 文件浏览器）后，确认大文件读取出错、连接不稳定、播放体验差、界面老旧与广告隐私顾虑等痛点仍未被满足，恢复条件成立。当前按"大文件可靠性 -> 连接稳定性 -> 播放体验 -> 浏览搜索"顺序收口，下文的未完成风险清单在对应切片完成前继续有效。

`iosRemoteFolder` 是一个 SwiftUI 统一资源查看器，目标是在 iPhone/iPad 中浏览本地、HTTP/HTTPS、Alist 和 WebDAV 资源，并按 PDF、Markdown、TXT、图片、视频和音频选择查看方式。

## 为什么曾经暂停

项目进入大量实现后，才重新意识到市场上已有成熟的综合文件管理产品。这里并没有独立核验某个竞品的全部运行能力；触发暂停的是工作区所有者对 ES 文件浏览器的观察。真正的问题不是“已有竞品，所以不该做”，而是本项目在开始完整开发前没有证明以下三件事：

- 哪一类用户的现有痛点仍未被满足；
- 用户为什么会从成熟产品切换过来；
- 本项目能用哪项可验证差异形成持续价值。

在这些问题没有答案时继续扩大功能和 Agent 并行度，只会更快地产生工程资产，不会自动产生产品价值。

## 冻结快照包含什么

- Swift 6、SwiftUI、SwiftData 和 iOS 17+ App 基础结构；
- Home、Browse、Sources、Offline 四个顶层区域；
- 统一资源身份、typed metadata、revision、能力和内容会话模型；
- 本地文件、HTTP/HTTPS、WebDAV/Alist 的连接、目录、认证、Range 和错误边界实验；
- PDF、Markdown、TXT、图片、音频和视频的查看器切片；
- 最近打开、阅读/播放位置、revision-aware 缓存和缓存内容离线打开实验；
- 跨已浏览目录的 SwiftData 索引/搜索实验；
- 基于 `AVAssetResourceLoader` 和有界 Range 会话的大音频/视频播放实验。

## 当前验证证据

2026-08-11，Codex 主程在 iPhone 17 Pro / iOS 26.5 Simulator 上完成：

- HTTP、WebDAV、`ResourceAccessServiceTests`、`SessionMediaPlayerTests` 专项测试通过；
- 完整 Swift Testing 测试 target 通过；
- generic iOS Simulator Debug 构建通过；
- `xcodebuild analyze` 退出码为 0；
- `git diff --check` 通过。

这些结果只证明当前受控 fixture 和模拟器快照没有已知失败，不等于真实 Alist、NAS、Files Provider 或大媒体真机流程已经完成产品验收。构建仍报告 PDFKit 相关的 Swift 6 actor-isolation warnings。

## 未完成与已知风险

### 搜索（D-050，未验收）

- 来源删除或命名空间变化后的索引清理失败，可能留下旧记录；
- 同一 source ID 更换 endpoint 后，旧路径可能被错误地用于新命名空间；
- UI 未充分说明搜索范围仅限“已浏览目录”；
- 查询和刷新存在全表读取的 O(N) 扩展风险；
- 损坏记录可能被静默跳过。

### Alist/WebDAV 大媒体（D-052，未验收）

- 整个媒体 prepare 流程没有统一 deadline；
- 完整 GET 路径仍可能在预算判断前形成较大内存数据；
- 已知长度的完整正文没有统一执行精确长度校验；
- 会话缺少强对象 validator，同长度替换可能混入不同版本的 Range；
- WebDAV redirect rejection 的错误归属仍可能受并发请求影响；
- 新下载热路径和真实 iPhone 大 MP3/MP4 播放、seek、取消、退出仍缺最终验收。

其他未完成项包括真实外部 Files Provider 生命周期、SMB/SFTP、后台下载、完整离线任务、缓存容量治理、后台音频和 Now Playing。

## 运行

用 Xcode 打开 `iosRemoteFolder.xcodeproj`，选择 `iosRemoteFolder` scheme，在 iOS Simulator 或真机运行。远端来源需要由使用者自行填写；仓库不包含测试服务器、用户名或密码。明文 HTTP 是否可访问仍受 iOS App Transport Security 配置约束。

## 仓库性质与许可

本仓库作为学习和复盘快照公开。仓库未附带 `LICENSE`；公开可见不等于获得复制、修改、分发或商业使用授权。
