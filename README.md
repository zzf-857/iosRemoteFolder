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
- 101 个 Swift Testing fixture 测试和托管测试 target
- PDF、Markdown、TXT、图片、视频、音乐六类独立查看器入口；演示来源的 PDF/Markdown/TXT/图片/音乐/视频均已接入受预算真实内容读取
- D-035 自适应与无障碍壳已通过主程验收：辅助字号布局、VoiceOver 语义、Reduce Motion、方向声明和 disclosure 所有权均已收口
- D-028A 已通过主程验收：唯一 `SourceRegistry`、注入式 `SourcesStore`、`ResourceAccessService` 和受预算/可取消的 `ResourceContentSession` 已建立
- D-028B 已通过主程复核：`ResourceViewerHost` 经 `ResourceAccessService` 创建会话并获取最新 typed metadata，加载、失败、取消和重试状态均有结构化生命周期
- D-030A 已通过 Codex 主程复核：Local adapter 增加 bookmark 位置值、stale/失效重新授权错误、平衡 security-scoped lease 和 `NSFileCoordinator` 协调访问
- D-030B 已实现，主程构建/测试基线复核通过，真实 Files Provider 生命周期待验证：Files 目录选择、bookmark 配置恢复、动态来源注册/替换/移除和 stale/失效重新授权均由 composition root 接线；临时 Codable + UserDefaults 后端只保存 bookmark 与非敏感来源描述
- D-033A/D-033B 已实现 WebDAV/Alist `/dav/` 读取与来源恢复闭环：Sources 页面可添加远端来源，非敏感 descriptor 通过版本化窄存储恢复，用户名/密码只通过 Keychain credential reference 关联；`PROPFIND Depth: 0/1` 解析 `DAV:` namespace、目录、typed metadata/revision，Basic Auth 只在运行时请求头中传递，GET/Range 复用现有 HTTP 传输与预算/取消/响应校验，Info.plist 声明本地网络用途并启用最小本地 ATS 例外
- D-033C 已实现 WebDAV/Alist 重定向安全边界：PROPFIND、HEAD/Range 和完整 GET 只接受同源且仍位于规范化 endpoint 根路径内的跳转；跨 origin、路径逃逸、query/fragment、URL 凭证和 method 改写被拒绝，HTTP 直链保留既有行为；异常 `HEAD 206` 不会伪造完整大小或 Range 能力
- iOS 26 AppIcon 基础资源已接入 Asset Catalog：无文字文件夹/远程入口符号、1024px marketing 图和 iPhone/iPad 多尺寸图标已加入 App target
- D-036/D-037/D-038/D-039/D-040 功能闭环切片已实现：`ViewerRegistry` 按 typed metadata/UTType/MIME/扩展名解析，TXT 使用显式 10 MiB 预算和编码探测，PDF/图片/视频使用显式 50 MiB 预算，演示图片通过原生缩放/平移查看器呈现，演示音频通过 `AVAudioPlayer` 播放，演示视频通过内存资源加载器交给 `AVPlayer` 播放；D-030B 外部 Provider 证据、SwiftData/Keychain 和其他协议仍未提前视为完成
- D-041 已实现：成功打开的资源按 `ResourceIdentity` 去重并恢复到 Home 的“继续/最近打开”，最多保留 20 条；临时存储不含 URL、请求头、Token、Cookie 或绝对路径，后续迁移到 SwiftData 不改变身份键语义
- D-042 已实现：音频/视频查看器按 `ResourceIdentity + ResourceRevision` 保存和恢复播放时间点；unknown 或变化的 revision 不恢复，视频异步时长解析后再恢复
- D-043 已实现：PDF 保存当前页，TXT/Markdown 保存规范化纵向阅读比例；仅在 identity 与已知 revision 同时匹配时恢复，未知或变化 revision 自动清理，持久记录不含 URL、凭证或正文
- D-044 已实现：查看器先获取最新 typed metadata，再按 `ResourceIdentity + ResourceRevision + content variant` 读取持久缓存；缓存缺失、超预算、损坏或解码失败时受预算回源并原子写入，manifest 只保存非敏感 identity 映射，Offline 页面投影真实缓存内容并支持清理
- D-045 已实现：Offline 已缓存资源通过同一 `ResourceAccessService` 创建缓存后端会话，在来源不可用时复用已知 revision 的完整内容进入现有查看器；缺失、损坏、unknown revision 和超预算保持明确失败

当前阶段：

- D-030B Files 来源配置生命周期已实现，主程构建/测试基线已通过，真实 Files Provider stale/失效 bookmark、授权和恢复语义仍待验证；D-033A/D-033B/D-033C 已完成 WebDAV/Alist `/dav/` 的 adapter、来源添加、descriptor/Keychain 恢复、目录浏览、内容读取和重定向安全接线，真实 WebDAV/NAS/Alist 服务互操作、DNS rebinding 和 SwiftData 全量迁移仍待专项验证；D-036/D-037/D-038/D-039/D-040 已把 TXT/PDF/Markdown/图片/演示音乐/视频推进为受控真实内容路径，D-041 已接通最近资源投影，D-042/D-043 已接通媒体与文档阅读位置恢复，D-044 已接通 revision-aware 内容缓存，D-045 已接通缓存内容离线查看。

尚未完成：

- SMB/SFTP 等其他真实协议 adapter；WebDAV/Alist 的具体服务端互操作专项验证仍待完成
- SwiftData 非敏感来源配置全量迁移、真实 WebDAV/NAS/Alist 互操作、跨 origin/DNS rebinding 重定向防护、其他真实协议 adapter 和其余格式的生产级内容解码
- 后台下载、缓存淘汰和完整离线下载；D-045 只覆盖已经缓存内容的离线打开
- 真实远端视频流式/长视频策略、后台音频/Now Playing/队列、文档搜索/批注和 Files Provider 离线语义

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

当前主程记录位于工作区的 `Project/todolist/alist-media-player/`，实际仓库当前 `main` 包含尚未推送到 `origin/main` 的本地中文 commit；D-024、D-029、D-035、D-028A、D-028B 会话状态门、D-030A、D-033A/D-033B、D-036/D-037/D-038/D-039/D-040 内容闭环、D-041/D-042/D-043 恢复闭环和 D-044/D-045 缓存闭环均已完成主程复核，D-030B Files 配置生命周期已实现且主程基线通过，真实 Files Provider 生命周期、WebDAV/Alist 生产互操作、后台下载和完整离线语义仍待后续专项验证。
