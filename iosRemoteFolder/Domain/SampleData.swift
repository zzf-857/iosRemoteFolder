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
            sourceID: personalSourceID,
            logicalPath: ResourcePath(rawValue: "/知识库/设计/设计系统与组件规范.pdf")!,
            name: "设计系统与组件规范.pdf",
            kind: .pdf,
            metadata: metadata(
                byteSize: 18_400_000,
                modifiedAt: Date(timeIntervalSince1970: 1_754_450_000),
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                acceptsRanges: true
            ),
            capabilities: [.read, .rangeRead, .download, .thumbnail, .search],
            accent: .orange
        ),
        ResourceItem(
            sourceID: workSourceID,
            logicalPath: ResourcePath(rawValue: "/产品/路线图.md")!,
            name: "产品路线图.md",
            kind: .markdown,
            metadata: metadata(
                byteSize: 42 * 1024,
                modifiedAt: Date(timeIntervalSince1970: 1_754_700_000),
                mimeType: "text/markdown",
                typeIdentifier: "net.daringfireball.markdown"
            ),
            capabilities: [.read, .download, .search],
            accent: .teal
        ),
        ResourceItem(
            sourceID: workSourceID,
            logicalPath: ResourcePath(rawValue: "/运维/服务器部署日志.txt")!,
            name: "服务器部署日志.txt",
            kind: .text,
            metadata: metadata(
                byteSize: 2_800_000,
                modifiedAt: Date(timeIntervalSince1970: 1_754_100_000),
                mimeType: "text/plain",
                typeIdentifier: "public.plain-text"
            ),
            capabilities: [.read, .download, .search],
            accent: .blue
        ),
        ResourceItem(
            sourceID: workSourceID,
            logicalPath: ResourcePath(rawValue: "/产品/路线图封面.png")!,
            name: "路线图封面.png",
            kind: .image,
            metadata: metadata(
                byteSize: 68,
                modifiedAt: Date(timeIntervalSince1970: 1_754_700_000),
                mimeType: "image/png",
                typeIdentifier: "public.png"
            ),
            capabilities: [.read, .download, .thumbnail],
            accent: .teal
        ),
        ResourceItem(
            sourceID: workSourceID,
            logicalPath: ResourcePath(rawValue: "/产品/路线图演示.wav")!,
            name: "路线图演示.wav",
            kind: .audio,
            metadata: metadata(
                byteSize: 16_044,
                modifiedAt: Date(timeIntervalSince1970: 1_754_700_000),
                mimeType: "audio/wav",
                typeIdentifier: "com.microsoft.waveform-audio"
            ),
            capabilities: [.read, .download],
            accent: .pink
        ),
        ResourceItem(
            sourceID: localSourceID,
            logicalPath: ResourcePath(rawValue: "/照片/旅行/海边-2026-01.jpg")!,
            name: "海边-2026-01.jpg",
            kind: .image,
            metadata: metadata(
                byteSize: 8_100_000,
                modifiedAt: Date(timeIntervalSince1970: 1_736_668_800),
                mimeType: "image/jpeg",
                typeIdentifier: "public.jpeg"
            ),
            capabilities: [.read, .download, .thumbnail],
            accent: .blue
        ),
        ResourceItem(
            sourceID: personalSourceID,
            logicalPath: ResourcePath(rawValue: "/视频/学习/WWDC 设计分享.mp4")!,
            name: "WWDC 设计分享.mp4",
            kind: .video,
            metadata: metadata(
                byteSize: 1_200_000_000,
                modifiedAt: Date(timeIntervalSince1970: 1_754_000_000),
                mimeType: "video/mp4",
                typeIdentifier: "public.mpeg-4",
                acceptsRanges: true
            ),
            capabilities: [.read, .rangeRead, .directURL, .download, .thumbnail],
            accent: .purple
        ),
        ResourceItem(
            sourceID: localSourceID,
            logicalPath: ResourcePath(rawValue: "/音乐/工作/深夜工作歌单.m4a")!,
            name: "深夜工作歌单.m4a",
            kind: .audio,
            metadata: metadata(
                byteSize: 74_200_000,
                modifiedAt: Date(timeIntervalSince1970: 1_754_450_000),
                mimeType: "audio/mp4",
                typeIdentifier: "public.mpeg-4-audio",
                acceptsRanges: true
            ),
            capabilities: [.read, .directURL, .download, .thumbnail],
            accent: .pink
        )
    ]

    private static func metadata(
        byteSize: Int64,
        modifiedAt: Date,
        mimeType: String,
        typeIdentifier: String,
        acceptsRanges: Bool = false
    ) -> ResourceMetadata {
        ResourceMetadata(
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            isDirectory: false,
            acceptsRanges: acceptsRanges,
            revision: ResourceRevision.strongest(
                etag: nil,
                serverVersion: nil,
                modifiedAt: modifiedAt,
                byteSize: byteSize
            )
        )
    }
}
