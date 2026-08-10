import Foundation
import SwiftUI
import PDFKit
import UIKit
import AVFoundation
import AVKit

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
        case ready(ResourceIdentity, ResourceMetadata, ViewerResolution, ViewerContentPayload?)
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
            case .ready(let identity, let metadata, let resolution, let payload) where identity == resource.id:
                readyView(metadata: metadata, resolution: resolution, payload: payload)
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
    private func readyView(
        metadata: ResourceMetadata,
        resolution: ViewerResolution,
        payload: ViewerContentPayload?
    ) -> some View {
        VStack(spacing: 0) {
            metadataSummary(metadata)
            viewerView(resolution: resolution, metadata: metadata, payload: payload)
        }
    }

    @ViewBuilder
    private func viewerView(
        resolution: ViewerResolution,
        metadata: ResourceMetadata,
        payload: ViewerContentPayload?
    ) -> some View {
        switch resolution.kind {
        case .pdfReader:
            if case .pdf(let data) = payload {
                PDFReaderView(resource: resource, data: data)
            } else {
                UnsupportedViewerView(resource: resource, reason: "PDF 内容读取无效")
            }
        case .markdownReader:
            if case .text(let text) = payload {
                MarkdownReaderView(resource: resource, text: text)
            } else {
                UnsupportedViewerView(resource: resource, reason: "Markdown 内容读取无效")
            }
        case .textReader:
            if case .text(let text) = payload {
                TextReaderView(resource: resource, text: text)
            } else {
                UnsupportedViewerView(resource: resource, reason: "文本内容读取无效")
            }
        case .imageViewer:
            if case .image(let data) = payload {
                ImageViewerView(resource: resource, data: data)
            } else {
                UnsupportedViewerView(resource: resource, reason: "图片内容读取无效")
            }
        case .videoPlayer:
            if case .video(let data) = payload {
                VideoPlayerView(resource: resource, metadata: metadata, data: data)
            } else {
                UnsupportedViewerView(resource: resource, reason: "视频内容读取无效")
            }
        case .musicPlayer:
            if case .audio(let data) = payload {
                MusicPlayerView(resource: resource, metadata: metadata, data: data)
            } else {
                UnsupportedViewerView(resource: resource, reason: "音乐内容读取无效")
            }
        case .systemPreview:
            UnsupportedViewerView(resource: resource, reason: resolution.fallbackDescription)
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
            let resolution = ViewerRegistry.resolve(resource: resource, metadata: metadata)
            let payload: ViewerContentPayload?
            switch resolution.preparation {
            case .none:
                payload = nil
            case .text(let maximumBytes):
                let data = try await createdSession.readData(maximumBytes: maximumBytes)
                try Task.checkCancellation()
                payload = .text(ViewerContentDecoder.decodeText(data))
            case .pdf(let maximumBytes):
                let data = try await createdSession.readData(maximumBytes: maximumBytes)
                try Task.checkCancellation()
                guard PDFDocument(data: data) != nil else {
                    throw ResourceSourceError.invalidResponse
                }
                payload = .pdf(data)
            case .image(let maximumBytes):
                let data = try await createdSession.readData(maximumBytes: maximumBytes)
                try Task.checkCancellation()
                guard ViewerContentDecoder.isValidImageData(data) else {
                    throw ResourceSourceError.invalidResponse
                }
                payload = .image(data)
            case .audio(let maximumBytes):
                let data = try await createdSession.readData(maximumBytes: maximumBytes)
                try Task.checkCancellation()
                guard ViewerContentDecoder.isValidAudioData(data) else {
                    throw ResourceSourceError.invalidResponse
                }
                payload = .audio(data)
            case .video(let maximumBytes):
                let data = try await createdSession.readData(maximumBytes: maximumBytes)
                try Task.checkCancellation()
                guard await ViewerContentDecoder.isValidVideoData(data) else {
                    throw ResourceSourceError.invalidResponse
                }
                payload = .video(data)
            }
            try Task.checkCancellation()
            if resolution.kind != .systemPreview {
                appModel.recordRecent(resource: resource, metadata: metadata)
            }
            result = .ready(request.identity, metadata, resolution, payload)
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

enum ViewerContentPayload: Equatable, Sendable {
    case text(String)
    case pdf(Data)
    case image(Data)
    case audio(Data)
    case video(Data)
}

enum ViewerContentDecoder {
    static func isValidImageData(_ data: Data) -> Bool {
        UIImage(data: data) != nil
    }

    static func isValidAudioData(_ data: Data) -> Bool {
        (try? AVAudioPlayer(data: data)) != nil
    }

    @MainActor
    static func isValidVideoData(_ data: Data) async -> Bool {
        let engine = AVVideoPlayerEngine(data: data)
        do {
            try await engine.prepare()
            engine.stop()
            return true
        } catch {
            engine.stop()
            return false
        }
    }

    static func decodeText(_ data: Data) -> String {
        let bytes = Array(data)
        let encodings: [String.Encoding]
        if hasPrefix(bytes, [0xFF, 0xFE, 0x00, 0x00]) || hasPrefix(bytes, [0x00, 0x00, 0xFE, 0xFF]) {
            encodings = [.utf32, .utf32LittleEndian, .utf32BigEndian, .utf8]
        } else if hasPrefix(bytes, [0xFF, 0xFE]) || hasPrefix(bytes, [0xFE, 0xFF]) {
            encodings = [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf8]
        } else if hasPrefix(bytes, [0xEF, 0xBB, 0xBF]) {
            encodings = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        } else if looksLikeUTF16(bytes) {
            encodings = [.utf16LittleEndian, .utf16BigEndian, .utf8]
        } else {
            encodings = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        }
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        for encoding in [String.Encoding.ascii, .isoLatin1, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        bytes.starts(with: prefix)
    }

    private static func looksLikeUTF16(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let oddZeroes = stride(from: 1, to: bytes.count, by: 2).reduce(into: 0) { count, index in
            if bytes[index] == 0 { count += 1 }
        }
        let evenZeroes = stride(from: 0, to: bytes.count, by: 2).reduce(into: 0) { count, index in
            if bytes[index] == 0 { count += 1 }
        }
        let sampleCount = bytes.count / 2
        return oddZeroes * 4 >= sampleCount || evenZeroes * 4 >= sampleCount
    }
}

struct PDFReaderView: View {
    let resource: ResourceItem
    private let document: PDFDocument?

    init(resource: ResourceItem, data: Data) {
        self.resource = resource
        self.document = PDFDocument(data: data)
    }

    var body: some View {
        Group {
            if let document {
                PDFDocumentView(document: document)
            } else {
                ContentUnavailableView(
                    "无法显示 PDF",
                    systemImage: "doc.richtext",
                    description: Text("文件内容不是有效的 PDF 文档。")
                )
            }
        }
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
    let text: String
    @State private var renderedMode = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ViewerHeader(icon: "text.badge.checkmark", eyebrow: "MARKDOWN READER", title: resource.name)
                Picker("显示模式", selection: $renderedMode) {
                    Text("渲染").tag(true)
                    Text("源码").tag(false)
                }
                .pickerStyle(.segmented)

                if renderedMode {
                    if let rendered = try? AttributedString(markdown: text) {
                        Text(rendered)
                            .textSelection(.enabled)
                    } else {
                        Text(text.isEmpty ? "（空文件）" : text)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(text.isEmpty ? "（空文件）" : text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding()
        }
    }
}

struct TextReaderView: View {
    let resource: ResourceItem
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "（空文件）" : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    let data: Data

    @State private var committedScale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = UIImage(data: data) {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(committedScale * gestureScale)
                        .offset(
                            x: committedOffset.width + gestureOffset.width,
                            y: committedOffset.height + gestureOffset.height
                        )
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    gestureScale = value
                                }
                                .onEnded { value in
                                    committedScale = min(max(committedScale * value, 1), 4)
                                    gestureScale = 1
                                    if committedScale == 1 {
                                        committedOffset = .zero
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard committedScale > 1 || gestureScale > 1 else { return }
                                    gestureOffset = value.translation
                                }
                                .onEnded { value in
                                    guard committedScale > 1 else {
                                        gestureOffset = .zero
                                        return
                                    }
                                    committedOffset.width += value.translation.width
                                    committedOffset.height += value.translation.height
                                    gestureOffset = .zero
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel(Text("\(resource.name)，图片"))
                        .accessibilityValue(Text("可缩放和平移"))
                }
            } else {
                ContentUnavailableView(
                    "无法显示图片",
                    systemImage: "photo",
                    description: Text("文件内容不是有效的图片。")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重置", systemImage: "arrow.counterclockwise") {
                    committedScale = 1
                    gestureScale = 1
                    committedOffset = .zero
                    gestureOffset = .zero
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

@MainActor
struct VideoPlayerView: View {
    @Environment(AppModel.self) private var appModel
    let resource: ResourceItem
    let metadata: ResourceMetadata
    let data: Data
    @State private var engine: AVVideoPlayerEngine?
    @State private var restoredPosition = false

    init(resource: ResourceItem, metadata: ResourceMetadata, data: Data) {
        self.resource = resource
        self.metadata = metadata
        self.data = data
        _engine = State(initialValue: AVVideoPlayerEngine(data: data))
    }

    var body: some View {
        Group {
            if let engine {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    ScrollView {
                        VStack(spacing: 18) {
                            VideoPlayer(player: engine.player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .accessibilityLabel(Text("\(resource.name)，视频播放器"))

                            Slider(
                                value: Binding(
                                    get: { engine.currentTime },
                                    set: { engine.seek(to: $0) }
                                ),
                                in: 0...max(engine.duration, 0.001)
                            )
                            .accessibilityLabel("播放进度")

                            HStack {
                                Text(Self.timeLabel(engine.currentTime))
                                Spacer()
                                Text(Self.timeLabel(engine.duration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                            HStack(spacing: 32) {
                                Button("后退 10 秒", systemImage: "gobackward.10") {
                                    engine.seek(to: engine.currentTime - 10)
                                }
                                Button(
                                    engine.isPlaying ? "暂停" : "播放",
                                    systemImage: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                                ) {
                                    if engine.isPlaying {
                                        engine.pause()
                                    } else {
                                        _ = engine.play()
                                    }
                                }
                                .font(.largeTitle)
                                Button("前进 10 秒", systemImage: "goforward.10") {
                                    engine.seek(to: engine.currentTime + 10)
                                }
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityElement(children: .contain)
                        }
                        .frame(maxWidth: 900)
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView(
                    "无法播放视频",
                    systemImage: "film",
                    description: Text("文件内容不是有效的视频。")
                )
            }
        }
        .onAppear {
            if let engine {
                restorePositionIfNeeded(engine)
            }
        }
        .task {
            guard let engine else { return }
            if engine.duration <= 0 {
                try? await engine.prepare()
            }
            guard !Task.isCancelled else { return }
            restorePositionIfNeeded(engine)
        }
        .onDisappear {
            if let engine {
                savePosition(engine)
                engine.stop()
            }
        }
    }

    private func restorePositionIfNeeded(_ engine: AVVideoPlayerEngine) {
        guard !restoredPosition else { return }
        guard case .seconds(let seconds) = appModel.resumePosition(
            for: resource,
            metadata: metadata
        ) else {
            restoredPosition = true
            return
        }
        guard engine.duration > 0 else {
            return
        }
        restoredPosition = true
        engine.seek(to: seconds)
    }

    private func savePosition(_ engine: AVVideoPlayerEngine) {
        let duration = engine.duration
        let currentTime = engine.currentTime
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return }
        if currentTime >= max(duration - 0.5, 0) {
            appModel.clearResumePosition(for: resource)
        } else {
            appModel.recordResumePosition(
                .seconds(currentTime),
                for: resource,
                metadata: metadata
            )
        }
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

@MainActor
struct MusicPlayerView: View {
    @Environment(AppModel.self) private var appModel
    let resource: ResourceItem
    let metadata: ResourceMetadata
    let data: Data
    @State private var engine: AVAudioPlayerEngine?
    @State private var restoredPosition = false

    init(resource: ResourceItem, metadata: ResourceMetadata, data: Data) {
        self.resource = resource
        self.metadata = metadata
        self.data = data
        _engine = State(initialValue: try? AVAudioPlayerEngine(data: data))
    }

    var body: some View {
        Group {
            if let engine {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    ScrollView {
                        VStack(spacing: 24) {
                            ViewerHeader(icon: "music.note", eyebrow: "MUSIC PLAYER", title: resource.name)
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
                                .multilineTextAlignment(.center)
                            Slider(
                                value: Binding(
                                    get: { engine.currentTime },
                                    set: { engine.seek(to: $0) }
                                ),
                                in: 0...max(engine.duration, 0.001)
                            )
                            .accessibilityLabel("播放进度")
                            HStack {
                                Text(Self.timeLabel(engine.currentTime))
                                Spacer()
                                Text(Self.timeLabel(engine.duration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            HStack(spacing: 32) {
                                Button("后退 10 秒", systemImage: "gobackward.10") {
                                    engine.seek(to: engine.currentTime - 10)
                                }
                                Button(
                                    engine.isPlaying ? "暂停" : "播放",
                                    systemImage: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                                ) {
                                    if engine.isPlaying {
                                        engine.pause()
                                    } else {
                                        _ = engine.play()
                                    }
                                }
                                .font(.largeTitle)
                                Button("前进 10 秒", systemImage: "goforward.10") {
                                    engine.seek(to: engine.currentTime + 10)
                                }
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityElement(children: .contain)
                        }
                        .frame(maxWidth: 620)
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView(
                    "无法播放音乐",
                    systemImage: "music.note",
                    description: Text("文件内容不是有效的音频。")
                )
            }
        }
        .onAppear {
            if let engine {
                restorePositionIfNeeded(engine)
            }
        }
        .onDisappear {
            if let engine {
                savePosition(engine)
                engine.stop()
            }
        }
    }

    private func restorePositionIfNeeded(_ engine: AVAudioPlayerEngine) {
        guard !restoredPosition else { return }
        restoredPosition = true
        guard case .seconds(let seconds) = appModel.resumePosition(
            for: resource,
            metadata: metadata
        ) else {
            return
        }
        engine.seek(to: seconds)
    }

    private func savePosition(_ engine: AVAudioPlayerEngine) {
        let duration = engine.duration
        let currentTime = engine.currentTime
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return }
        if currentTime >= max(duration - 0.5, 0) {
            appModel.clearResumePosition(for: resource)
        } else {
            appModel.recordResumePosition(
                .seconds(currentTime),
                for: resource,
                metadata: metadata
            )
        }
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct UnsupportedViewerView: View {
    let resource: ResourceItem
    let reason: String?

    init(resource: ResourceItem, reason: String? = nil) {
        self.resource = resource
        self.reason = reason
    }

    var body: some View {
        ContentUnavailableView(
            "暂不支持此格式",
            systemImage: resource.kind.systemImage,
            description: Text(reason ?? "可以下载文件后使用系统分享或其他 App 打开。")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("分享", systemImage: "square.and.arrow.up") {}
            }
        }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        view.autoScales = true
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
