import Foundation
import SwiftUI
import PDFKit
import UIKit
import AVFoundation
import AVKit

enum ResourceViewerMode: Hashable, Sendable {
    case online
    case offline
}

enum MediaPreparationStrategy: Equatable, Sendable {
    case completeContent
    case rangeStream

    static let streamingThresholdBytes: Int64 = 4 * 1024 * 1024

    static func resolve(
        mode: ResourceViewerMode,
        metadata: ResourceMetadata
    ) -> MediaPreparationStrategy {
        guard mode == .online,
              metadata.acceptsRanges,
              let byteSize = metadata.byteSize,
              byteSize > streamingThresholdBytes else {
            return .completeContent
        }
        return .rangeStream
    }
}

struct ResourceViewerHost: View {
    @Environment(AppModel.self) private var appModel

    let resource: ResourceItem
    let mode: ResourceViewerMode
    @State private var loadState: LoadState = .loading
    @State private var retryAttempt = 0

    private struct LoadRequest: Hashable, Sendable {
        let identity: ResourceIdentity
        let attempt: Int
        let mode: ResourceViewerMode
    }

    private enum LoadState {
        case loading
        case ready(ResourceIdentity, ResourceMetadata, ViewerResolution, ViewerContentPayload?)
        case failed(ResourceIdentity, ResourceSourceError, diagnostic: String?)
        case cancelled(ResourceIdentity)
    }

    /// 打开流程的阶段标记：失败时随错误一起展示，直接定位失败环节。
    private enum LoadPhase: String {
        case session = "创建会话"
        case metadata = "获取元数据"
        case content = "读取内容"
        case enginePreparation = "准备播放引擎"
    }

    private var loadRequest: LoadRequest {
        LoadRequest(identity: resource.id, attempt: retryAttempt, mode: mode)
    }

    init(
        resource: ResourceItem,
        mode: ResourceViewerMode = .online
    ) {
        self.resource = resource
        self.mode = mode
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                loadingView
            case .ready(let identity, let metadata, let resolution, let payload) where identity == resource.id:
                readyView(metadata: metadata, resolution: resolution, payload: payload)
            case .failed(let identity, let error, let diagnostic) where identity == resource.id:
                failureView(error: error, diagnostic: diagnostic)
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
        if resolution.kind == .videoPlayer,
           case .video(let engine) = payload {
            VideoPlayerScreen(
                resource: resource,
                metadata: metadata,
                engine: engine,
                onRetry: { retryMedia(engine) }
            )
        } else {
            VStack(spacing: 0) {
                metadataSummary(metadata)
                viewerView(resolution: resolution, metadata: metadata, payload: payload)
            }
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
                PDFReaderView(resource: resource, metadata: metadata, data: data)
            } else {
                UnsupportedViewerView(resource: resource, reason: "PDF 内容读取无效")
            }
        case .markdownReader:
            if case .text(let text) = payload {
                MarkdownReaderView(resource: resource, metadata: metadata, text: text)
            } else {
                UnsupportedViewerView(resource: resource, reason: "Markdown 内容读取无效")
            }
        case .textReader:
            if case .text(let text) = payload {
                TextReaderView(resource: resource, metadata: metadata, text: text)
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
            if case .video(let engine) = payload {
                VideoPlayerView(
                    resource: resource,
                    metadata: metadata,
                    engine: engine,
                    onRetry: { retryMedia(engine) }
                )
            } else {
                UnsupportedViewerView(resource: resource, reason: "视频内容读取无效")
            }
        case .musicPlayer:
            if case .audio(let engine) = payload {
                MusicPlayerView(
                    resource: resource,
                    metadata: metadata,
                    engine: engine,
                    onRetry: { retryMedia(engine) }
                )
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

    private func failureView(error: ResourceSourceError, diagnostic: String?) -> some View {
        ContentUnavailableView {
            Label("无法打开资源", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 6) {
                Text(error.localizedDescription)
                #if DEBUG
                // 调试构建显示失败环节与底层错误，便于真机排障。
                if let diagnostic {
                    Text(diagnostic)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                #endif
            }
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

    private func retryMedia(_ engine: AVMediaPlayerEngine) {
        engine.stop()
        retry()
    }

    @MainActor
    private func load(request: LoadRequest, resource: ResourceItem) async {
        guard request == loadRequest else { return }
        loadState = .loading

        var session: ResourceContentSession?
        var preparedMediaEngine: AVMediaPlayerEngine?
        var mediaEngineOwnsSession = false
        var phase: LoadPhase = .session
        let result: LoadState
        do {
            let createdSession: ResourceContentSession
            switch mode {
            case .online:
                createdSession = try await appModel.resourceAccessService.makeSession(for: resource)
            case .offline:
                createdSession = try await appModel.resourceAccessService.makeOfflineSession(for: resource)
            }
            session = createdSession
            phase = .metadata
            let metadata = try await createdSession.fetchMetadata()
            phase = .content
            let resolution = ViewerRegistry.resolve(resource: resource, metadata: metadata)
            let payload: ViewerContentPayload?
            switch resolution.preparation {
            case .none:
                payload = nil
            case .text(let maximumBytes):
                let data = try await readContent(
                    from: createdSession,
                    metadata: metadata,
                    maximumBytes: maximumBytes,
                    usePersistentCache: mode == .online
                ) { _ in }
                payload = .text(ViewerContentDecoder.decodeText(data))
            case .pdf(let maximumBytes):
                let data = try await readContent(
                    from: createdSession,
                    metadata: metadata,
                    maximumBytes: maximumBytes,
                    usePersistentCache: mode == .online
                ) { data in
                    guard PDFDocument(data: data) != nil else {
                        throw ResourceSourceError.invalidResponse
                    }
                }
                payload = .pdf(data)
            case .image(let maximumBytes):
                let data = try await readContent(
                    from: createdSession,
                    metadata: metadata,
                    maximumBytes: maximumBytes,
                    usePersistentCache: mode == .online
                ) { data in
                    guard ViewerContentDecoder.isValidImageData(data) else {
                        throw ResourceSourceError.invalidResponse
                    }
                }
                payload = .image(data)
            case .audio(let maximumBytes):
                phase = .enginePreparation
                let prepared = try await prepareMedia(
                    from: createdSession,
                    metadata: metadata,
                    maximumBytes: maximumBytes,
                    expectedMediaType: .audio
                )
                preparedMediaEngine = prepared.engine
                mediaEngineOwnsSession = prepared.ownsSession
                payload = .audio(prepared.engine)
            case .video(let maximumBytes):
                phase = .enginePreparation
                let prepared = try await prepareMedia(
                    from: createdSession,
                    metadata: metadata,
                    maximumBytes: maximumBytes,
                    expectedMediaType: .video
                )
                preparedMediaEngine = prepared.engine
                mediaEngineOwnsSession = prepared.ownsSession
                payload = .video(prepared.engine)
            }
            try Task.checkCancellation()
            if mode == .online, resolution.kind != .systemPreview {
                appModel.recordRecent(resource: resource, metadata: metadata)
                await appModel.refreshOfflineCache()
            }
            result = .ready(request.identity, metadata, resolution, payload)
        } catch {
            result = state(for: error, identity: request.identity, phase: phase)
        }

        let shouldPublish = request == loadRequest && !Task.isCancelled
        if shouldPublish {
            loadState = result
        }

        let publishedMediaEngine: Bool
        if shouldPublish, preparedMediaEngine != nil, case .ready = result {
            publishedMediaEngine = true
            preparedMediaEngine = nil
            if mediaEngineOwnsSession {
                session = nil
            }
        } else {
            publishedMediaEngine = false
        }
        if !publishedMediaEngine {
            preparedMediaEngine?.stop()
        }

        // Full-data viewers release their source session after preparation.
        // Streaming media transfers the session to its resource loader.
        if let session {
            await session.close()
        }
    }

    /// 媒体准备（内容读取 + 引擎准备）共用一个统一 deadline，超时映射为
    /// 可重试的 `.timedOut`，不再依赖各阶段自身的空闲超时兜底。
    @MainActor
    private func prepareMedia(
        from session: ResourceContentSession,
        metadata: ResourceMetadata,
        maximumBytes: Int64,
        expectedMediaType: AVMediaType
    ) async throws -> (engine: AVMediaPlayerEngine, ownsSession: Bool) {
        let deadline = ContinuousClock().now
            + .seconds(AVMediaPlayerEngine.defaultPreparationTimeoutSeconds)
        if MediaPreparationStrategy.resolve(mode: mode, metadata: metadata) == .rangeStream {
            let engine = try AVMediaPlayerEngine(
                session: session,
                metadata: metadata,
                resourcePath: resource.path
            )
            try await prepareEngine(
                engine,
                expectedMediaType: expectedMediaType,
                deadline: deadline
            )
            return (engine, true)
        }

        var preparedDataEngine: AVMediaPlayerEngine?
        do {
            _ = try await readContent(
                from: session,
                metadata: metadata,
                maximumBytes: maximumBytes,
                usePersistentCache: mode == .online,
                deadline: deadline
            ) { data in
                let candidate = try AVMediaPlayerEngine(
                    data: data,
                    metadata: metadata,
                    resourcePath: resource.path
                )
                try await prepareEngine(
                    candidate,
                    expectedMediaType: expectedMediaType,
                    deadline: deadline
                )
                preparedDataEngine = candidate
            }
            guard let preparedDataEngine else {
                throw ResourceSourceError.invalidResponse
            }
            return (preparedDataEngine, false)
        } catch {
            preparedDataEngine?.stop()
            throw error
        }
    }

    @MainActor
    private func prepareEngine(
        _ engine: AVMediaPlayerEngine,
        expectedMediaType: AVMediaType,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                try await engine.prepare(
                    expectedMediaType: expectedMediaType,
                    deadline: deadline
                )
            } onCancel: {
                Task { @MainActor in
                    engine.stop()
                }
            }
            try Task.checkCancellation()
        } catch {
            engine.stop()
            throw error
        }
    }

    /// 让一个可发送结果的异步操作受统一 deadline 约束；到期取消底层操作并
    /// 抛出 `.timedOut`。deadline 为 nil 时保持原有无额外约束的行为。
    private static func awaitWithDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let deadline else { return try await operation() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                return nil
            }
            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                guard let value = outcome else {
                    throw ResourceSourceError.timedOut
                }
                return value
            }
            throw ResourceSourceError.cancelled
        }
    }

    @MainActor
    private func readContent(
        from session: ResourceContentSession,
        metadata: ResourceMetadata,
        maximumBytes: Int64,
        usePersistentCache: Bool,
        deadline: ContinuousClock.Instant? = nil,
        validate: (Data) async throws -> Void
    ) async throws -> Data {
        let key = usePersistentCache
            ? ResourceCacheKey(
                identity: resource.id,
                revision: metadata.revision,
                variant: .content
            )
            : nil

        if let key,
           let cached = try? await appModel.cacheCoordinator.data(
               for: key,
               maximumBytes: maximumBytes
           ) {
            do {
                try Task.checkCancellation()
                try await validate(cached)
                try Task.checkCancellation()
                return cached
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw ResourceSourceError.cancelled
                }
                let sourceError = ResourceSourceError.mapping(error)
                guard sourceError == .invalidResponse else {
                    throw sourceError
                }
                // Only deterministic content invalidity evicts the entry. A
                // transient playback or network error must preserve valid cache.
                await appModel.cacheCoordinator.removeData(for: key)
            }
        }

        let data = try await Self.awaitWithDeadline(deadline) {
            try await session.readData(maximumBytes: maximumBytes)
        }
        try Task.checkCancellation()
        try await validate(data)
        try Task.checkCancellation()
        if let key {
            _ = try? await appModel.cacheCoordinator.store(
                data,
                for: key,
                maximumBytes: maximumBytes
            )
        }
        return data
    }

    private func state(
        for error: any Error,
        identity: ResourceIdentity,
        phase: LoadPhase
    ) -> LoadState {
        if Task.isCancelled {
            return .cancelled(identity)
        }
        let sourceError = (error as? ResourceSourceError) ?? ResourceSourceError.mapping(error)
        if sourceError == .cancelled {
            return .cancelled(identity)
        }
        // 诊断串只含阶段与错误结构，不含 URL、请求头或凭证。
        let diagnostic = "阶段：\(phase.rawValue)｜\(String(reflecting: error))"
        return .failed(identity, sourceError, diagnostic: diagnostic)
    }
}

enum ViewerContentPayload {
    case text(String)
    case pdf(Data)
    case image(Data)
    case audio(AVMediaPlayerEngine)
    case video(AVMediaPlayerEngine)
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
        let metadata = ResourceMetadata(
            byteSize: Int64(data.count),
            mimeType: "video/mp4",
            typeIdentifier: "public.mpeg-4"
        )
        guard let engine = try? AVMediaPlayerEngine(
            data: data,
            metadata: metadata,
            resourcePath: "/fixture.mp4"
        ) else {
            return false
        }
        do {
            try await engine.prepare(expectedMediaType: .video)
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

@MainActor
struct PDFReaderView: View {
    @Environment(AppModel.self) private var appModel
    let resource: ResourceItem
    let metadata: ResourceMetadata
    private let document: PDFDocument?
    @State private var currentPageIndex = 0

    init(resource: ResourceItem, metadata: ResourceMetadata, data: Data) {
        self.resource = resource
        self.metadata = metadata
        self.document = PDFDocument(data: data)
    }

    private var savedPageIndex: Int? {
        guard let document,
              case .pdf(let pageIndex) = appModel.readingPosition(
                  for: resource,
                  metadata: metadata
              ) else {
            return nil
        }
        return min(max(pageIndex, 0), max(document.pageCount - 1, 0))
    }

    var body: some View {
        Group {
            if let document {
                PDFDocumentView(
                    document: document,
                    initialPageIndex: savedPageIndex,
                    onPageChange: { currentPageIndex = $0 }
                )
            } else {
                ContentUnavailableView(
                    "无法显示 PDF",
                    systemImage: "doc.richtext",
                    description: Text("文件内容不是有效的 PDF 文档。")
                )
            }
        }
        .onAppear {
            if let savedPageIndex {
                currentPageIndex = savedPageIndex
            }
        }
        .onDisappear {
            guard let document, document.pageCount > 0,
                  metadata.revision.isKnown else { return }
            appModel.recordReadingPosition(
                .pdf(pageIndex: min(max(currentPageIndex, 0), document.pageCount - 1)),
                for: resource,
                metadata: metadata
            )
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

@MainActor
struct MarkdownReaderView: View {
    @Environment(AppModel.self) private var appModel
    let resource: ResourceItem
    let metadata: ResourceMetadata
    let text: String
    @State private var renderedMode = true
    @State private var currentFraction: Double?

    init(resource: ResourceItem, metadata: ResourceMetadata, text: String) {
        self.resource = resource
        self.metadata = metadata
        self.text = text
    }

    private var savedFraction: Double? {
        guard case .text(let fraction) = appModel.readingPosition(
            for: resource,
            metadata: metadata
        ) else {
            return nil
        }
        return fraction
    }

    private var displayedText: NSAttributedString {
        if renderedMode, let rendered = try? AttributedString(markdown: text) {
            return NSAttributedString(rendered)
        }
        let value = text.isEmpty ? "（空文件）" : text
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let font = renderedMode
            ? bodyFont
            : UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        return NSAttributedString(
            string: value,
            attributes: [.font: font, .foregroundColor: UIColor.label]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewerHeader(kind: .markdown, title: resource.name)
            Picker("显示模式", selection: $renderedMode) {
                Text("渲染").tag(true)
                Text("源码").tag(false)
            }
            .pickerStyle(.segmented)
            ReadingTextView(
                attributedText: displayedText,
                initialFraction: currentFraction ?? savedFraction,
                onFractionChange: { currentFraction = $0 }
            )
            .frame(maxWidth: 720, maxHeight: .infinity)
        }
        .padding()
        .onAppear {
            if currentFraction == nil {
                currentFraction = savedFraction ?? 0
            }
        }
        .onDisappear {
            guard let fraction = currentFraction ?? savedFraction,
                  metadata.revision.isKnown else { return }
            appModel.recordReadingPosition(
                .text(fraction: fraction),
                for: resource,
                metadata: metadata
            )
        }
    }
}

@MainActor
struct TextReaderView: View {
    @Environment(AppModel.self) private var appModel
    let resource: ResourceItem
    let metadata: ResourceMetadata
    let text: String
    @State private var currentFraction: Double?

    init(resource: ResourceItem, metadata: ResourceMetadata, text: String) {
        self.resource = resource
        self.metadata = metadata
        self.text = text
    }

    private var savedFraction: Double? {
        guard case .text(let fraction) = appModel.readingPosition(
            for: resource,
            metadata: metadata
        ) else {
            return nil
        }
        return fraction
    }

    var body: some View {
        ReadingTextView(
            attributedText: NSAttributedString(
                string: text.isEmpty ? "（空文件）" : text,
                attributes: [
                    .font: UIFont.monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                        weight: .regular
                    ),
                    .foregroundColor: UIColor.label
                ]
            ),
            initialFraction: currentFraction ?? savedFraction,
            onFractionChange: { currentFraction = $0 }
        )
        .padding()
        .onAppear {
            if currentFraction == nil {
                currentFraction = savedFraction ?? 0
            }
        }
        .onDisappear {
            guard let fraction = currentFraction ?? savedFraction,
                  metadata.revision.isKnown else { return }
            appModel.recordReadingPosition(
                .text(fraction: fraction),
                for: resource,
                metadata: metadata
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("搜索", systemImage: "magnifyingglass") {}
                Button("字体", systemImage: "textformat.size") {}
            }
        }
    }
}

private struct ReadingTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let initialFraction: Double?
    let onFractionChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFractionChange: onFractionChange)
    }

    func makeUIView(context: Context) -> PositionAwareTextView {
        let view = PositionAwareTextView()
        view.delegate = context.coordinator
        view.attributedText = attributedText
        view.pendingFraction = initialFraction
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PositionAwareTextView, context: Context) {
        context.coordinator.onFractionChange = onFractionChange
        if !view.attributedText.isEqual(to: attributedText) {
            view.attributedText = attributedText
        }
        if let initialFraction {
            view.pendingFraction = initialFraction
            view.setNeedsLayout()
        }
    }

    static func dismantleUIView(_ view: PositionAwareTextView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.view = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var view: PositionAwareTextView?
        var onFractionChange: (Double) -> Void

        init(onFractionChange: @escaping (Double) -> Void) {
            self.onFractionChange = onFractionChange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view, !view.isApplyingPosition else { return }
            onFractionChange(view.currentFraction)
        }
    }
}

private final class PositionAwareTextView: UITextView {
    var pendingFraction: Double?
    private(set) var isApplyingPosition = false

    var currentFraction: Double {
        let minimumY = -adjustedContentInset.top
        let maximumY = max(
            minimumY,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        guard maximumY > minimumY else { return 0 }
        return min(max((contentOffset.y - minimumY) / (maximumY - minimumY), 0), 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let pendingFraction, bounds.height > 0 else { return }

        let minimumY = -adjustedContentInset.top
        let maximumY = max(
            minimumY,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        guard maximumY > minimumY else {
            if pendingFraction == 0 {
                self.pendingFraction = nil
            }
            return
        }

        self.pendingFraction = nil
        isApplyingPosition = true
        setContentOffset(
            CGPoint(
                x: contentOffset.x,
                y: minimumY + (maximumY - minimumY) * min(max(pendingFraction, 0), 1)
            ),
            animated: false
        )
        isApplyingPosition = false
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = true
        backgroundColor = .clear
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
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
    let engine: AVMediaPlayerEngine
    let onRetry: () -> Void
    @State private var restoredPosition = false
    @State private var nowPlaying = MediaNowPlayingController()

    init(
        resource: ResourceItem,
        metadata: ResourceMetadata,
        engine: AVMediaPlayerEngine,
        onRetry: @escaping () -> Void
    ) {
        self.resource = resource
        self.metadata = metadata
        self.engine = engine
        self.onRetry = onRetry
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            ZStack {
                MediaAmbientBackground(kind: .video)
                ScrollView {
                    VStack(spacing: 20) {
                        VideoPlayer(player: engine.player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.30), radius: 24, y: 10)
                            .disabled(engine.playbackState.disablesControls)
                            .allowsHitTesting(!engine.playbackState.disablesControls)
                            .accessibilityLabel(Text("\(resource.name)，视频播放器"))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(resource.name)
                                .font(.headline)
                                .fontDesign(.rounded)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(resource.kind.title) · \(ResourceMetadataFormatter.size(for: metadata))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)

                        MediaPlaybackControls(
                            engine: engine,
                            onSeekCommitted: { nowPlaying.refresh() }
                        ) {
                            savePosition(engine)
                            onRetry()
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding()
                }
            }
        }
        .onAppear {
            restorePositionIfNeeded(engine)
            nowPlaying.activate(title: resource.name, engine: engine, isVideo: true)
        }
        .onDisappear {
            savePosition(engine)
            engine.stop()
            nowPlaying.deactivate()
        }
        .onChange(of: engine.playbackState) { _, _ in
            nowPlaying.refresh()
        }
    }

    private func restorePositionIfNeeded(_ engine: AVMediaPlayerEngine) {
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

    private func savePosition(_ engine: AVMediaPlayerEngine) {
        guard engine.playbackState != .stopped else { return }
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

}

@MainActor
struct MusicPlayerView: View {
    @Environment(AppModel.self) private var appModel
    let resource: ResourceItem
    let metadata: ResourceMetadata
    let engine: AVMediaPlayerEngine
    let onRetry: () -> Void
    @State private var restoredPosition = false
    @State private var nowPlaying = MediaNowPlayingController()

    init(
        resource: ResourceItem,
        metadata: ResourceMetadata,
        engine: AVMediaPlayerEngine,
        onRetry: @escaping () -> Void
    ) {
        self.resource = resource
        self.metadata = metadata
        self.engine = engine
        self.onRetry = onRetry
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            ZStack {
                MediaAmbientBackground(kind: .audio)
                ScrollView {
                    VStack(spacing: 26) {
                        artwork
                        VStack(spacing: 6) {
                            Text(resource.name)
                                .font(.title2.bold())
                                .fontDesign(.rounded)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(resource.kind.title) · \(ResourceMetadataFormatter.size(for: metadata))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        MediaPlaybackControls(
                            engine: engine,
                            onSeekCommitted: { nowPlaying.refresh() }
                        ) {
                            savePosition(engine)
                            onRetry()
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            restorePositionIfNeeded(engine)
            nowPlaying.activate(title: resource.name, engine: engine, isVideo: false)
        }
        .onDisappear {
            savePosition(engine)
            engine.stop()
            nowPlaying.deactivate()
        }
        .onChange(of: engine.playbackState) { _, _ in
            nowPlaying.refresh()
        }
    }

    /// 大幅渐变封面：音频类型光谱 + 音符符号，取代旧的浅色占位块。
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(ResourceKind.audio.gradient)
            Image(systemName: "music.note")
                .font(.system(size: 92, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 330)
        .shadow(
            color: (ResourceKind.audio.gradientColors.first ?? .clear).opacity(0.42),
            radius: 30,
            y: 14
        )
        .accessibilityHidden(true)
    }

    private func restorePositionIfNeeded(_ engine: AVMediaPlayerEngine) {
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

    private func savePosition(_ engine: AVMediaPlayerEngine) {
        guard engine.playbackState != .stopped else { return }
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

}

/// 媒体页氛围背景：类型光谱渐变经超薄材质柔化，深浅色自适应。
private struct MediaAmbientBackground: View {
    let kind: ResourceKind

    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: kind.gradientColors.map { $0.opacity(0.32) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

@MainActor
private struct MediaPlaybackControls: View {
    let engine: AVMediaPlayerEngine
    var onSeekCommitted: (() -> Void)? = nil
    let onRetry: () -> Void

    /// 拖动中的目标位置：拖动期间只更新显示，松手后才执行一次精确 seek，
    /// 避免流式大文件在拖动过程中触发密集的随机读取。
    @State private var scrubbingTime: TimeInterval?
    /// 是否处于连续拖动手势中（由 `onEditingChanged` 维护）。
    @State private var isScrubbing = false

    private var displayedTime: TimeInterval {
        scrubbingTime ?? engine.currentTime
    }

    var body: some View {
        VStack(spacing: 12) {
            runtimeStatus

            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { value in
                        if isScrubbing {
                            scrubbingTime = value
                        } else {
                            // VoiceOver 可调节操作等离散调整不经过连续手势，
                            // 保持即时提交语义，避免调整永不生效。
                            engine.seek(to: value)
                            onSeekCommitted?()
                        }
                    }
                ),
                in: 0...max(engine.duration, 0.001),
                onEditingChanged: { isEditing in
                    isScrubbing = isEditing
                    guard !isEditing, let target = scrubbingTime else { return }
                    scrubbingTime = nil
                    engine.seek(to: target)
                    onSeekCommitted?()
                }
            )
            .tint(AppTheme.accent)
            .disabled(engine.playbackState.disablesControls)
            .accessibilityLabel("播放进度")
            .accessibilityValue(
                Text("\(Self.timeLabel(displayedTime)) / \(Self.timeLabel(engine.duration))")
            )

            HStack {
                Text(Self.timeLabel(displayedTime))
                Spacer()
                Text(Self.timeLabel(engine.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 40) {
                Button {
                    engine.seek(to: engine.currentTime - 10)
                    onSeekCommitted?()
                } label: {
                    Label("后退 10 秒", systemImage: "gobackward.10")
                        .labelStyle(.iconOnly)
                        .font(.title2.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.primary)

                Button {
                    if engine.playbackState.showsPauseControl {
                        engine.pause()
                    } else {
                        _ = engine.play()
                    }
                } label: {
                    Label(
                        engine.playbackState.showsPauseControl ? "暂停" : "播放",
                        systemImage: engine.playbackState.showsPauseControl
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(AppTheme.brandGradient, in: Circle())
                    .shadow(color: AppTheme.accent.opacity(0.38), radius: 12, y: 5)
                }

                Button {
                    engine.seek(to: engine.currentTime + 10)
                    onSeekCommitted?()
                } label: {
                    Label("前进 10 秒", systemImage: "goforward.10")
                        .labelStyle(.iconOnly)
                        .font(.title2.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.primary)
            }
            .disabled(engine.playbackState.disablesControls)
            .accessibilityElement(children: .contain)
        }
        .padding(18)
        .modernCard(cornerRadius: 26)
        .onChange(of: engine.playbackState) { _, state in
            // 手势中控件被禁用时 SwiftUI 不保证回调 onEditingChanged(false)，
            // 显式清理拖动状态，避免时间显示永久停在悬挂的拖动值。
            if state.disablesControls {
                isScrubbing = false
                scrubbingTime = nil
            }
        }
    }

    @ViewBuilder
    private var runtimeStatus: some View {
        switch engine.playbackState {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在准备播放")
            }
            .accessibilityElement(children: .combine)
        case .waiting:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在缓冲")
            }
            .accessibilityElement(children: .combine)
        case .failed(let error):
            VStack(spacing: 10) {
                Label("播放失败", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试", systemImage: "arrow.clockwise") {
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
        case .ended:
            Label("播放结束", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .stopped:
            Label("播放已停止", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .playing, .paused:
            EmptyView()
        }
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private extension AVMediaPlayerEngine.PlaybackState {
    var disablesControls: Bool {
        switch self {
        case .preparing, .failed, .stopped:
            true
        case .waiting, .playing, .paused, .ended:
            false
        }
    }

    var showsPauseControl: Bool {
        switch self {
        case .waiting, .playing:
            true
        case .preparing, .paused, .failed, .ended, .stopped:
            false
        }
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

@MainActor
private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    let initialPageIndex: Int?
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .secondarySystemBackground
        context.coordinator.attach(to: view)
        context.coordinator.apply(pageIndex: initialPageIndex, to: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        if view.document !== document {
            view.document = document
            context.coordinator.appliedPageIndex = nil
        }
        view.autoScales = true
        if context.coordinator.appliedPageIndex != initialPageIndex {
            context.coordinator.apply(pageIndex: initialPageIndex, to: view)
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPageChange: (Int) -> Void
        var appliedPageIndex: Int?
        private weak var observedView: PDFView?

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func attach(to view: PDFView) {
            detach()
            observedView = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange(_:)),
                name: Notification.Name.PDFViewPageChanged,
                object: view
            )
        }

        @objc
        private func pageDidChange(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  view === observedView,
                  let page = view.currentPage,
                  let document = view.document else {
                return
            }
            let index = document.index(for: page)
            guard index >= 0 else { return }
            appliedPageIndex = index
            onPageChange(index)
        }

        func apply(pageIndex: Int?, to view: PDFView) {
            guard let pageIndex,
                  let page = view.document?.page(at: max(pageIndex, 0)) else {
                appliedPageIndex = nil
                return
            }
            appliedPageIndex = min(max(pageIndex, 0), max((view.document?.pageCount ?? 1) - 1, 0))
            view.go(to: page)
            onPageChange(appliedPageIndex ?? 0)
        }

        func detach() {
            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name.PDFViewPageChanged,
                object: observedView
            )
            observedView = nil
        }

    }
}

private struct ViewerHeader: View {
    let kind: ResourceKind
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            ResourceIconTile(kind: kind, side: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                    .fontDesign(.rounded)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
