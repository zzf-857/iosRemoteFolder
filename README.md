# iosRemoteFolder

面向 iPhone/iPad 的统一资源查看器：集中浏览本地、HTTP/HTTPS、Alist、WebDAV 和局域网来源，按 PDF、Markdown、TXT、图片、视频、音乐分别提供内容体验。

## 当前进展

已完成：

- Swift 6 + SwiftUI App 壳，最低 iOS/iPadOS 17+，以 iOS 26 为主要验收环境
- Home、Browse、Sources、Offline 四个顶层区域
- `ResourceSource`、`ResourceItem`、`ResourceReference`、`ResourceCapability` 统一领域模型
- `ResourceSourceAdapter` 协议 v2：连接、列举、引用、元数据、读取和统一错误映射
- 本地文件与 HTTP/HTTPS 读取基础，包含 Range/重定向/请求头边界和连接状态仓库
- Sources 页面连接中、失败、重试状态
- 49 个 Swift Testing fixture 测试和托管测试 target
- PDF、Markdown、TXT、图片、视频、音乐六类独立查看器入口与假数据流程

当前正在进行：

- 主程复核来源读取契约修复；现有实现已完成主要修复，但仍需补齐 HTTP 206 响应完整性校验、枚举阶段 scheme 校验和 Range 能力缓存身份边界
- 通过来源基础验收后，先解决真实来源目录下钻与资源稳定 ID，再接入第一个 PDF/TXT 真实查看器

尚未完成：

- Alist、WebDAV、SMB/SFTP 等真实协议 adapter
- 用户可配置来源、Keychain 凭证存储、SwiftData 索引和完整离线下载
- 真实 PDF/Markdown/TXT/图片/视频/音乐内容解码与生产级缓存

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

当前主程记录位于工作区的 `Project/todolist/alist-media-player/`，实际仓库当前 `main` 包含尚未推送到 `origin/main` 的本地中文 commit；来源读取契约修复仍未最终验收。
