# iosRemoteFolder

统一资源查看器的 iOS 原生工程骨架。

当前阶段只提供：

- Swift 6 + SwiftUI 的 App 壳
- Home、Browse、Sources、Offline 四个顶层区域
- `ResourceSource`、`ResourceItem`、`ResourceCapability` 等统一领域模型
- Sources、Indexing、Cache、Viewers、Playback、UI 模块边界
- PDF、Markdown、TXT、图片、视频、音乐六类独立查看器入口
- 假数据浏览和查看器跳转流程

真实 Alist、WebDAV、局域网协议、缓存持久化和内容解码按项目待办逐步接入。

## 打开工程

使用 Xcode 打开 `iosRemoteFolder.xcodeproj`，选择 `iosRemoteFolder` scheme 后运行 iOS Simulator 或真机。

最低系统暂定 iOS/iPadOS 17+，开发验收以 iOS 26 为主。

## 目录边界

```text
iosRemoteFolder/
  App/          App 入口和根导航
  Domain/       资源领域模型与假数据
  Sources/      来源适配器协议
  Indexing/     索引服务
  Cache/        缓存状态与协调器
  Viewers/      六类专属查看器和注册表
  Playback/     播放引擎边界
  UI/           主题、玻璃功能层和通用资源组件
```

