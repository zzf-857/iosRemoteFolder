import SwiftUI

struct ResourceViewerHost: View {
    @Environment(AppModel.self) private var appModel

    let resource: ResourceItem
    @State private var loadState: LoadState = .loading
    @State private var retryAttempt = 0

    private struct LoadRequest: Hashable, Sendable {
        let identity: ResourceIdentity
        let attempt: Int
    }

    private enum LoadState: Equatable {
        case loading
        case ready(ResourceIdentity, ResourceMetadata)
        case failed(ResourceIdentity, ResourceSourceError)
        case cancelled(ResourceIdentity)
    }

    private var loadRequest: LoadRequest {
        LoadRequest(identity: resource.id, attempt: retryAttempt)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                loadingView
            case .ready(let identity, let metadata) where identity == resource.id:
                readyView(metadata: metadata)
            case .failed(let identity, let error) where identity == resource.id:
                failureView(error: error)
            case .cancelled(let identity) where identity == resource.id:
                cancelledView
            default:
                // A result from a cancelled task must never be shown for a new
                // resource while its replacement session is being prepared.
                loadingView
            }
        }
        .navigationTitle(resource.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadRequest) {
            await load(request: loadRequest, resource: resource)
        }
    }

    @ViewBuilder
    private func readyView(metadata: ResourceMetadata) -> some View {
        VStack(spacing: 0) {
            metadataSummary(metadata)
            viewerView
        }
    }

    @ViewBuilder
    private var viewerView: some View {
        switch ViewerRegistry.viewer(for: resource) {
        case .pdfReader:
            PDFReaderView(resource: resource)
        case .markdownReader:
            MarkdownReaderView(resource: resource)
        case .textReader:
            TextReaderView(resource: resource)
        case .imageViewer:
            ImageViewerView(resource: resource)
        case .videoPlayer:
            VideoPlayerView(resource: resource)
        case .musicPlayer:
            MusicPlayerView(resource: resource)
        case .systemPreview:
            UnsupportedViewerView(resource: resource)
        }
    }

    private func metadataSummary(_ metadata: ResourceMetadata) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(resource.kind.title, systemImage: resource.kind.systemImage)
                Text(ResourceMetadataFormatter.size(for: metadata))
                Text(ResourceMetadataFormatter.modified(for: metadata))
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(resource.kind.title, systemImage: resource.kind.systemImage)
                HStack(spacing: 12) {
                    Text(ResourceMetadataFormatter.size(for: metadata))
                    Text(ResourceMetadataFormatter.modified(for: metadata))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                "\(resource.name)，\(resource.kind.title)，"
                    + "\(ResourceMetadataFormatter.size(for: metadata))，"
                    + "\(ResourceMetadataFormatter.modified(for: metadata))"
            )
        )
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Label("正在准备资源", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("正在获取最新资源信息")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
    }

    private func failureView(error: ResourceSourceError) -> some View {
        ContentUnavailableView {
            Label("无法打开资源", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("重试", systemImage: "arrow.clockwise") {
                retry()
            }
        }
    }

    private var cancelledView: some View {
        ContentUnavailableView {
            Label("已取消打开", systemImage: "xmark.circle")
        } description: {
            Text("资源信息读取已取消")
        } actions: {
            Button("重试", systemImage: "arrow.clockwise") {
                retry()
            }
        }
    }

    private func retry() {
        loadState = .loading
        retryAttempt += 1
    }

    @MainActor
    private func load(request: LoadRequest, resource: ResourceItem) async {
        guard request == loadRequest else { return }
        loadState = .loading

        var session: ResourceContentSession?
        let result: LoadState
        do {
            let createdSession = try await appModel.resourceAccessService.makeSession(for: resource)
            session = createdSession
            let metadata = try await createdSession.fetchMetadata()
            try Task.checkCancellation()
            result = .ready(request.identity, metadata)
        } catch {
            result = state(for: error, identity: request.identity)
        }

        // A session may outlive the metadata probe. Closing it here covers
        // normal completion, retries, identity changes and task cancellation.
        if let session {
            await session.close()
        }

        guard request == loadRequest else { return }
        loadState = Task.isCancelled ? .cancelled(request.identity) : result
    }

    private func state(for error: any Error, identity: ResourceIdentity) -> LoadState {
        if Task.isCancelled {
            return .cancelled(identity)
        }
        let sourceError = (error as? ResourceSourceError) ?? ResourceSourceError.mapping(error)
        if sourceError == .cancelled {
            return .cancelled(identity)
        }
        return .failed(identity, sourceError)
    }
}

struct PDFReaderView: View {
    let resource: ResourceItem
    @State private var page = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ViewerHeader(icon: "doc.richtext.fill", eyebrow: "PDF READER", title: "纸张与分页")
                ForEach(1...3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                        .frame(height: 290)
                        .overlay {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("第 \(index) 页")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(resource.name.replacingOccurrences(of: ".pdf", with: ""))
                                    .font(.title2.bold())
                                Text("PDFKit 查看器将在此处承载分页、搜索、目录、缩放和远端 Range 读取。")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(24)
                        }
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("搜索", systemImage: "magnifyingglass") {}
                    Button("目录", systemImage: "list.bullet") {}
                    Button("分享", systemImage: "square.and.arrow.up") {}
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

struct MarkdownReaderView: View {
    let resource: ResourceItem
    @State private var renderedMode = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ViewerHeader(icon: "text.badge.checkmark", eyebrow: "MARKDOWN READER", title: "结构化长文")
                Picker("显示模式", selection: $renderedMode) {
                    Text("渲染").tag(true)
                    Text("源码").tag(false)
                }
                .pickerStyle(.segmented)

                if renderedMode {
                    Text("产品路线图")
                        .font(.largeTitle.bold())
                    Text("统一资源查看器的内容层以阅读优先，来源协议隐藏在 ResourceReference 后面。")
                        .font(.title3)
                    Divider()
                    Text("当前骨架已经为 Textual、代码块、表格、远端图片和标题导航预留独立承载区。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("# \(resource.name)\n\nResourceReference -> ViewerRegistry -> MarkdownReader")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("目录", systemImage: "list.bullet.indent") {}
            }
        }
    }
}

struct TextReaderView: View {
    let resource: ResourceItem

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text("001  server started\n002  loading remote source\n003  authenticated\n004  indexing directory\n005  ready\n\nTXT Reader 将在此处承载编码检测、换行、搜索、行号和长文本分段读取。")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("搜索", systemImage: "magnifyingglass") {}
                Button("字体", systemImage: "textformat.size") {}
            }
        }
    }
}

struct ImageViewerView: View {
    let resource: ResourceItem

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(AppTheme.accent)
                Text(resource.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Nuke/NukeUI 原图管线与自有缩放画布")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("收藏", systemImage: "star") {}
                Button("信息", systemImage: "info.circle") {}
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct VideoPlayerView: View {
    let resource: ResourceItem
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(white: 0.12))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Image(systemName: "film.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(AppTheme.accent)
                    }
                VStack(spacing: 12) {
                    Slider(value: .constant(0.28))
                    HStack {
                        Text("00:42")
                        Spacer()
                        Text("24:18")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    HStack(spacing: 26) {
                        Button("后退", systemImage: "gobackward.10") {}
                        Button(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                            isPlaying.toggle()
                        }
                        Button("前进", systemImage: "goforward.10") {}
                    }
                    .font(.title2)
                }
            }
            .padding()
        }
        .foregroundStyle(.white)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct MusicPlayerView: View {
    let resource: ResourceItem
    @State private var isPlaying = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ViewerHeader(icon: "music.note", eyebrow: "MUSIC PLAYER", title: "队列与系统媒体")
                RoundedRectangle(cornerRadius: 26)
                    .fill(AppTheme.accent.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 72))
                            .foregroundStyle(AppTheme.accent)
                    }
                Text(resource.name)
                    .font(.title2.bold())
                Text("本地导入 · 04:32")
                    .foregroundStyle(.secondary)
                Slider(value: .constant(0.42))
                HStack(spacing: 32) {
                    Button("随机", systemImage: "shuffle") {}
                    Button("上一首", systemImage: "backward.fill") {}
                    Button(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                        isPlaying.toggle()
                    }
                    .font(.largeTitle)
                    Button("下一首", systemImage: "forward.fill") {}
                    Button("队列", systemImage: "list.bullet") {}
                }
                .labelStyle(.iconOnly)
            }
            .frame(maxWidth: 620)
            .padding()
        }
    }
}

struct UnsupportedViewerView: View {
    let resource: ResourceItem

    var body: some View {
        ContentUnavailableView(
            "暂不支持此格式",
            systemImage: resource.kind.systemImage,
            description: Text("可以下载文件后使用系统分享或其他 App 打开。")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("分享", systemImage: "square.and.arrow.up") {}
            }
        }
    }
}

private struct ViewerHeader: View {
    let icon: String
    let eyebrow: String
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.title.bold())
            }
            Spacer()
        }
    }
}
