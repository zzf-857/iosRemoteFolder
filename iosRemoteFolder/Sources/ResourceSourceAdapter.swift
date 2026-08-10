import Foundation

/// 统一来源适配器协议。
///
/// 查看器、缓存与 UI 只消费 `ResourceItem`、`ResourceReference` 和
/// `ResourceSourceState`，不感知具体协议；每个来源实现一个 adapter。
/// 连接状态由 `SourcesStore` 根据下列异步方法的结果汇总，adapter 自身
/// 不持有 UI 状态。UI 禁止直接调用 URLSession 或 FileManager。
protocol ResourceSourceAdapter: Sendable {
    /// 来源的静态描述；实时连接状态通过 `SourcesStore` 报告。
    var source: ResourceSource { get }

    /// 探测并建立连接。失败时抛出可行动的 `ResourceSourceError`。
    func connect() async throws

    /// 列举指定逻辑目录下的直接子项（文件夹与文件），这是唯一必需的列举语义。
    /// 本地来源解析真实子目录，HTTP 来源在已配置直链上构建虚拟目录树；
    /// 规范化后的逻辑路径必须唯一，重复路径须明确报 `invalidReference`，
    /// 不能由 `first(where:)` 静默选择。
    func listResources(at path: ResourcePath) async throws -> [ResourceItem]

    /// 为资源生成统一引用；未知资源抛出 `ResourceSourceError.invalidReference`。
    func reference(for item: ResourceItem) async throws -> ResourceReference

    /// 探测资源元数据（本地文件属性或 HTTP HEAD）。
    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata

    /// 读取资源数据；`range` 为 nil 表示完整读取。
    /// 不支持区间读取的来源必须显式降级或抛出 `capabilityUnavailable`。
    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data
}

extension ResourceSourceAdapter {
    /// 根目录兼容入口；严格且只向唯一必需的带路径入口转发。
    func listResources() async throws -> [ResourceItem] {
        try await listResources(at: .root)
    }
}

/// 统一的来源错误。所有 adapter 抛出的底层错误都必须映射到这里，
/// 保证 UI、测试和日志看到的是同一套可解释、可行动的错误语义。
enum ResourceSourceError: LocalizedError, Hashable, Sendable {
    /// 认证失效或需要重新认证（HTTP 401、URLSession 认证质询）。
    case authenticationRequired
    /// 本地 security-scoped bookmark 已失效或需要用户重新选择目录。
    case authorizationRequired
    /// 无权限访问（本地文件权限、HTTP 403）。
    case permissionDenied
    /// 资源或来源不存在（本地 ENOENT、HTTP 404）。
    case notFound
    /// 连接或读取超时。
    case timedOut
    /// 用户或系统取消了操作。
    case cancelled
    /// 其余非 2xx 的 HTTP 状态码。
    case httpStatus(Int)
    /// 网络不可达：断网、DNS 失败、拒绝连接等。
    case networkUnavailable
    /// 引用无效：URL 编码错误、路径穿越、缺少必要参数。
    case invalidReference
    /// 来源不支持请求的能力。
    case capabilityUnavailable
    /// 服务器未支持区间读取，且全量响应超出安全预算；为避免整文件进内存而中止读取。
    case responseTooLarge
    /// 服务器响应违反约定（Content-Range 非法、响应体长度不符、区间请求收到异常 2xx），无法保证数据完整。
    case invalidResponse
    /// 来源失效或其他暂时无法归类的失败。
    case unavailable

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "来源需要重新认证"
        case .authorizationRequired: "本地来源需要重新授权，请重新选择文件夹"
        case .permissionDenied: "没有权限访问该资源"
        case .notFound: "资源不存在或已被删除"
        case .timedOut: "连接超时，请检查网络后重试"
        case .cancelled: "操作已取消"
        case .httpStatus(let code): "服务器返回异常状态码 \(code)"
        case .networkUnavailable: "无法连接到来源，请检查网络或地址"
        case .invalidReference: "资源引用无效"
        case .capabilityUnavailable: "此来源不支持当前操作"
        case .responseTooLarge: "服务器未支持分段读取，响应内容超出安全上限。请改用完整下载，或联系服务端开启 Range 支持"
        case .invalidResponse: "远端响应无效或不完整，无法确认数据完整。请重试，或检查服务端配置"
        case .unavailable: "来源暂时不可用"
        }
    }

    /// 值得让用户立即重试的错误。
    var isRetryable: Bool {
        switch self {
        case .timedOut, .networkUnavailable, .unavailable, .invalidResponse:
            return true
        case .httpStatus(let code):
            return code >= 500
        default:
            return false
        }
    }

    /// 将底层系统错误映射为统一的来源错误。
    static func mapping(_ error: any Error) -> ResourceSourceError {
        if let sourceError = error as? ResourceSourceError {
            return sourceError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            case .userAuthenticationRequired:
                return .authenticationRequired
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                return .networkUnavailable
            case .badURL, .unsupportedURL:
                return .invalidReference
            default:
                return .unavailable
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            switch cocoa.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notFound
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied
            default:
                break
            }
        }
        return .unavailable
    }

    /// HTTP 状态码到来源错误的映射；可行动语义单独成类，其余保留状态码。
    static func http(statusCode: Int) -> ResourceSourceError {
        switch statusCode {
        case 401: .authenticationRequired
        case 403: .permissionDenied
        case 404: .notFound
        default: .httpStatus(statusCode)
        }
    }
}

/// 演示来源 adapter：在真实 Alist / WebDAV adapter 接入前提供可浏览的
/// 受控文档内容。内容只属于开发演示路径，不代表真实协议或远端数据能力。
struct SampleSourceAdapter: ResourceSourceAdapter {
    let source: ResourceSource

    func connect() async throws {
        try await Task.sleep(for: .milliseconds(120))
        guard source.status != .needsAttention else {
            throw ResourceSourceError.authenticationRequired
        }
    }

    func listResources(at path: ResourcePath) async throws -> [ResourceItem] {
        try await connect()
        let all = SampleData.resources.filter { $0.sourceID == source.id }
        guard !path.isRoot else { return all }
        // 按规范化路径过滤：直接子文件保留，深层资源合成必要的虚拟文件夹。
        var folderNames: [String: String] = [:]
        var fileItems: [String: ResourceItem] = [:]
        for item in all {
            guard let itemPath = ResourcePath(rawValue: item.path), itemPath.isUnder(path) else { continue }
            let remaining = itemPath.components.dropFirst(path.components.count)
            if remaining.count == 1 {
                fileItems[item.path] = item
            } else if remaining.count > 1,
                      let folderName = remaining.first,
                      let folderPath = path.child(folderName) {
                folderNames[folderPath.normalized] = folderName
            }
        }
        let folders = folderNames.map { (folderPath, folderName) in
            ResourceItem(
                sourceID: source.id,
                logicalPath: ResourcePath(rawValue: folderPath)!,
                name: folderName,
                kind: .folder,
                metadata: ResourceMetadata(isDirectory: true),
                capabilities: [.list],
                accent: .recommended(for: .folder)
            )
        }
        let sortedFolders = folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sortedFiles = fileItems.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return sortedFolders + sortedFiles
    }

    func reference(for item: ResourceItem) async throws -> ResourceReference {
        throw ResourceSourceError.capabilityUnavailable
    }

    func fetchMetadata(for item: ResourceItem) async throws -> ResourceMetadata {
        let sample = try sampleItem(for: item)
        guard let content = Self.content(for: sample.path) else {
            throw ResourceSourceError.capabilityUnavailable
        }
        var metadata = sample.metadata
        let byteSize = Int64(content.count)
        metadata.byteSize = byteSize
        metadata.revision = ResourceRevision.strongest(
            etag: nil,
            serverVersion: nil,
            modifiedAt: metadata.modifiedAt,
            byteSize: byteSize
        )
        return metadata
    }

    func readData(for item: ResourceItem, range: ResourceByteRange?) async throws -> Data {
        let sample = try sampleItem(for: item)
        guard let content = Self.content(for: sample.path) else {
            throw ResourceSourceError.capabilityUnavailable
        }
        try Task.checkCancellation()
        guard let range else { return content }
        guard let clamped = range.clamped(toTotalLength: Int64(content.count)) else {
            return Data()
        }
        let lower = Int(clamped.lowerBound)
        let upper = Int(clamped.upperBound) + 1
        return content.subdata(in: lower..<upper)
    }

    private func sampleItem(for item: ResourceItem) throws -> ResourceItem {
        guard item.sourceID == source.id,
              item.id.sourceID == source.id,
              item.id.logicalPath == item.path,
              let path = ResourcePath(rawValue: item.path),
              path.normalized == item.path,
              let sample = SampleData.resources.first(where: {
                  $0.sourceID == source.id && $0.path == path.normalized
              }) else {
            throw ResourceSourceError.invalidReference
        }
        guard sample.kind != .folder, !sample.metadata.isDirectory else {
            throw ResourceSourceError.invalidReference
        }
        return sample
    }

    private static func content(for path: String) -> Data? {
        switch path {
        case "/产品/路线图.md":
            return Data(
                """
                # 产品路线图

                这是统一资源查看器的第一条真实文档内容路径。

                ## 当前阶段

                - 来源列举会返回规范化的逻辑路径
                - 内容读取经过受预算的 ResourceContentSession
                - TXT、Markdown 和 PDF 共享同一套来源生命周期

                > 这份内容来自演示来源，仅用于验证浏览到阅读的完整链路。
                """.utf8
            )
        case "/运维/服务器部署日志.txt":
            return Data(
                """
                2026-08-10 09:00 连接来源
                2026-08-10 09:02 完成根目录列举
                2026-08-10 09:03 获取最新 metadata
                2026-08-10 09:04 通过受控会话读取文本
                """.utf8
            )
        case "/产品/路线图封面.png":
            // A tiny valid raster keeps the demo path offline and deterministic.
            return Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        case "/产品/路线图演示.wav":
            return Self.makeWAV()
        case "/产品/路线图演示.mp4":
            return Self.makeMP4()
        case "/知识库/设计/设计系统与组件规范.pdf":
            return Self.makePDF()
        default:
            return nil
        }
    }

    /// Generate one second of a quiet 440 Hz tone in a standard PCM WAV container.
    private static func makeWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount: UInt32 = 8_000
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = frameCount * UInt32(blockAlign)

        var data = Data()
        data.append(contentsOf: Data("RIFF".utf8))

        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var littleEndianValue = value.littleEndian
            withUnsafeBytes(of: &littleEndianValue) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Data("WAVE".utf8))
        data.append(contentsOf: Data("fmt ".utf8))
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(channels)
        appendLittleEndian(sampleRate)
        appendLittleEndian(byteRate)
        appendLittleEndian(blockAlign)
        appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Data("data".utf8))
        appendLittleEndian(dataSize)
        let amplitude = Double(Int16.max) * 0.2
        for frame in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * 440 * Double(frame) / Double(sampleRate)
            appendLittleEndian(Int16(sin(phase) * amplitude))
        }
        return data
    }

    /// A deterministic one-second MP4 fixture used only for the demo content path.
    private static func makeMP4() -> Data {
        let base64 = [
            "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAARUbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAA",
            "AAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAA350cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAAB",
            "AAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAUAAAAC0AAAAAAAkZWR0cwAAABxlbHN0AAAAAAAA",
            "AAEAAAPoAAAEAAABAAAAAAL2bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAwAAAAMABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRl",
            "b0hhbmRsZXIAAAACoW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAmFzdGJsAAAAwXN0c2QA",
            "AAAAAAAAAQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAUAAtABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDAgbGlieDI2NAAAAAAAAAAAAAAA",
            "GP//AAAAN2F2Y0MBZAAM/+EAGmdkAAys2UFBn58BEAAAAwAQAAADAwDxQplgAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAACLA",
            "AAAAAAAAABhzdHRzAAAAAAAAAAEAAAAYAAACAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAyGN0dHMAAAAAAAAAFwAAAAEAAAQAAAAAAQAACgAAAAABAAAEAAAA",
            "AAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAoAAAAAAQAABAAAAAABAAAAAAAAAAEAAAIAAAAAAQAACgAAAAAB",
            "AAAEAAAAAAEAAAAAAAAAAQAAAgAAAAABAAAKAAAAAAEAAAQAAAAAAQAAAAAAAAABAAACAAAAAAEAAAgAAAAAAgAAAgAAAAAcc3RzYwAAAAAAAAABAAAAAQAA",
            "ABgAAAABAAAAdHN0c3oAAAAAAAAAAAAAABgAAALzAAAAEAAAAA0AAAANAAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAANAAAAFgAAAA8AAAAN",
            "AAAADQAAABYAAAAPAAAADQAAAA0AAAAWAAAADwAAAA0AAAAUc3RjbwAAAAAAAAABAAAEhAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1k",
            "aXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAwAAAACGZyZWUAAARgbWRhdAAAAq4GBf//qtxF6b3m",
            "2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBo",
            "dHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMg",
            "bWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0",
            "PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz02IGxvb2thaGVhZF90aHJlYWRzPTEgc2xp",
            "Y2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBi",
            "X3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21p",
            "bj0yNCBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWlu",
            "PTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAD1liIQAO//+46v4FKH6HMyjkyiK0Y0/PFJds8hM3HK/+B301YAAsYZb",
            "0KcZMlUbQASwAABLAzYYwmqnJPW3AAAADEGaJGxDv/6plgACBgAAAAlBnkJ4hf8AAm8AAAAJAZ5hdEK/AANSAAAACQGeY2pCvwADUwAAABJBmmhJqEFomUwI",
            "d//+qZYAAgcAAAALQZ6GRREsL/8AAm8AAAAJAZ6ldEK/AANTAAAACQGep2pCvwADUgAAABJBmqxJqEFsmUwId//+qZYAAgYAAAALQZ7KRRUsL/8AAm8AAAAJ",
            "AZ7pdEK/AANSAAAACQGe62pCvwADUgAAABJBmvBJqEFsmUwIb//+p4QAA/0AAAALQZ8ORRUsL/8AAm8AAAAJAZ8tdEK/AANTAAAACQGfL2pCvwADUgAAABJB",
            "mzRJqEFsmUwIZ//+nhAAD5gAAAALQZ9SRRUsL/8AAm8AAAAJAZ9xdEK/AANSAAAACQGfc2pCvwADUgAAABJBm3dJqEFsmUwIV//+OEAAPSEAAAALQZ+VRRUs",
            "K/8AA1IAAAAJAZ+2akK/AANT"
        ].joined()
        return Data(base64Encoded: base64) ?? Data()
    }

    /// 生成一个稳定、可由 PDFKit 打开的最小 PDF，避免演示内容依赖网络。
    private static func makePDF() -> Data {
        let stream = "BT /F1 20 Tf 72 720 Td (Resource viewer demo PDF) Tj ET\n"
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
            "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
            "5 0 obj\n<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream\nendobj\n"
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for object in objects {
            offsets.append(data.count)
            data.append(contentsOf: object.utf8)
        }
        let xrefOffset = data.count
        data.append(contentsOf: "xref\n0 \(objects.count + 1)\n".utf8)
        data.append(contentsOf: "0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            data.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        data.append(contentsOf: "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return data
    }
}
