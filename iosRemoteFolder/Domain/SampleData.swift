import Foundation

enum SampleData {
    static let personalSourceID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    static let workSourceID = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    static let localSourceID = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!
    static let httpSourceID = UUID(uuidString: "A0000000-0000-4000-8000-000000000004")!

    static let sources: [ResourceSource] = [
        ResourceSource(
            id: personalSourceID,
            name: "家庭资料库",
            kind: .alist,
            endpoint: "https://drive.example.com/dav",
            status: .connected,
            itemCountDescription: "1,284 个资源"
        ),
        ResourceSource(
            id: workSourceID,
            name: "工作 WebDAV",
            kind: .webdav,
            endpoint: "https://cloud.example.com",
            status: .indexing,
            itemCountDescription: "正在发现资源"
        ),
        ResourceSource(
            id: localSourceID,
            name: "本地导入",
            kind: .local,
            endpoint: "此设备 · 应用文稿目录",
            status: .localOnly,
            itemCountDescription: "36 个资源"
        ),
        ResourceSource(
            id: httpSourceID,
            name: "局域网直链示例",
            kind: .http,
            endpoint: "http://127.0.0.1:48080",
            status: .disconnected,
            itemCountDescription: "未连接"
        )
    ]

    static let resources: [ResourceItem] = [
        ResourceItem(
            name: "设计系统与组件规范.pdf",
            kind: .pdf,
            sourceID: personalSourceID,
            path: "/知识库/设计/设计系统与组件规范.pdf",
            sizeDescription: "18.4 MB",
            modifiedDescription: "昨天更新",
            capabilities: [.read, .rangeRead, .download, .thumbnail, .search],
            accent: .orange
        ),
        ResourceItem(
            name: "产品路线图.md",
            kind: .markdown,
            sourceID: workSourceID,
            path: "/产品/路线图.md",
            sizeDescription: "42 KB",
            modifiedDescription: "3 小时前",
            capabilities: [.read, .download, .search],
            accent: .teal
        ),
        ResourceItem(
            name: "服务器部署日志.txt",
            kind: .text,
            sourceID: workSourceID,
            path: "/运维/服务器部署日志.txt",
            sizeDescription: "2.8 MB",
            modifiedDescription: "周一更新",
            capabilities: [.read, .download, .search],
            accent: .blue
        ),
        ResourceItem(
            name: "海边-2026-01.jpg",
            kind: .image,
            sourceID: localSourceID,
            path: "/照片/旅行/海边-2026-01.jpg",
            sizeDescription: "8.1 MB",
            modifiedDescription: "1 月 12 日",
            capabilities: [.read, .download, .thumbnail],
            accent: .blue
        ),
        ResourceItem(
            name: "WWDC 设计分享.mp4",
            kind: .video,
            sourceID: personalSourceID,
            path: "/视频/学习/WWDC 设计分享.mp4",
            sizeDescription: "1.2 GB",
            modifiedDescription: "上周观看",
            capabilities: [.read, .rangeRead, .directURL, .download, .thumbnail],
            accent: .purple
        ),
        ResourceItem(
            name: "深夜工作歌单.m4a",
            kind: .audio,
            sourceID: localSourceID,
            path: "/音乐/工作/深夜工作歌单.m4a",
            sizeDescription: "74.2 MB",
            modifiedDescription: "昨天播放",
            capabilities: [.read, .directURL, .download, .thumbnail],
            accent: .pink
        )
    ]
}

