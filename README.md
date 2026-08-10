# iosRemoteFolder

面向 iPhone/iPad 的统一资源查看器：集中浏览本地、HTTP/HTTPS、Alist、WebDAV 和局域网来源，按 PDF、Markdown、TXT、图片、视频、音乐分别提供内容体验。

## 当前进展

已完成：

- Swift 6 + SwiftUI App 壳，最低 iOS/iPadOS 17+，以 iOS 26 为主要验收环境
- Home、Browse、Sources、Offline 四个顶层区域
- `ResourceSource`、`ResourceItem`、`ResourceReference`、`ResourceCapability` 统一领域模型
- `ResourceSourceAdapter` 协议 v2：连接、列举、引用、元数据、读取和统一错误映射
- 本地文件与 HTTP/HTTPS 读取基础，包含 Range/重定向/请求头边界和连接状态仓库
- HTTP 206 响应契约、Range 探测证据、能力缓存和 200 回退预算边界已收敛
- Sources 页面连接中、失败、重试状态
- 82 个 Swift Testing fixture 测试和托管测试 target
- PDF、Markdown、TXT、图片、视频、音乐六类独立查看器入口；演示来源的 PDF/Markdown/TXT/图片已接入受预算真实内容读取，视频和音乐仍保留占位流程
- D-035 自适应与无障碍壳已通过主程验收：辅助字号布局、VoiceOver 语义、Reduce Motion、方向声明和 disclosure 所有权均已收口
- D-028A 已通过主程验收：唯一 `SourceRegistry`、注入式 `SourcesStore`、`ResourceAccessService` 和受预算/可取消的 `ResourceContentSession` 已建立
- D-028B 已通过主程复核：`ResourceViewerHost` 经 `ResourceAccessService` 创建会话并获取最新 typed metadata，加载、失败、取消和重试状态均有结构化生命周期
- D-030A 已通过 Codex 主程复核：Local adapter 增加 bookmark 位置值、stale/失效重新授权错误、平衡 security-scoped lease 和 `NSFileCoordinator` 协调访问
- D-030B 已实现，主程构建/测试基线复核通过，真实 Files Provider 生命周期待验证：Files 目录选择、bookmark 配置恢复、动态来源注册/替换/移除和 stale/失效重新授权均由 composition root 接线；临时 Codable + UserDefaults 后端只保存 bookmark 与非敏感来源描述
- D-036/D-037/D-038 功能闭环切片已实现：`ViewerRegistry` 按 typed metadata/UTType/MIME/扩展名解析，TXT 使用显式 10 MiB 预算和编码探测，PDF 使用显式 50 MiB 预算与 PDFKit，演示图片通过显式 50 MiB 预算和原生缩放/平移查看器呈现；D-030B 外部 Provider 证据、SwiftData/Keychain 和其他协议仍未提前视为完成

当前阶段：

- D-030B Files 来源配置生命周期已实现，主程构建/75 项测试基线已通过，真实 Files Provider stale/失效 bookmark、授权和恢复语义仍待验证；D-036/D-037/D-038 已把 TXT/PDF/Markdown/图片推进为受控真实内容路径。本轮不进入 D-032 的 SwiftData/Keychain 迁移。

尚未完成：

- Alist、WebDAV、SMB/SFTP 等真实协议 adapter
- SwiftData/Keychain 配置迁移、真实协议 adapter 和其余格式的生产级内容解码
- 用户可配置来源、Keychain 凭证存储、SwiftData 索引和完整离线下载
- 视频/音乐内容解码、阅读位置恢复与生产级缓存

## 打开工程

使用 Xcode 打开 `iosRemoteFolder.xcodeproj`，选择 `iosRemoteFolder` scheme 后运行 iOS Simulator 或真机。

最低系统暂定 iOS/iPadOS 17+，开发验收以 iOS 26 为主。

## 目录边界

```text
iosRemoteFolder/
  App/          App 入口和根导航
  Domain/       资源领域模型与假数据
  Sources/      来源适配器、读取和连接状态仓库
  Indexing/     索引服务
  Cache/        缓存状态与协调器
  Viewers/      六类专属查看器和注册表
  Playback/     播放引擎边界
  UI/           主题、玻璃功能层和通用资源组件
```

当前主程记录位于工作区的 `Project/todolist/alist-media-player/`，实际仓库当前 `main` 包含尚未推送到 `origin/main` 的本地中文 commit；D-024、D-029、D-035、D-028A、D-028B 会话状态门、D-030A 和 D-036 TXT/PDF 内容闭环均已完成主程复核，D-030B Files 配置生命周期已实现且主程基线通过，真实 Files Provider 生命周期与其余格式内容仍待后续工作单。
