import Foundation
import Testing

@testable import iosRemoteFolder

@Suite("ResourceReference 与字节区间")
struct ResourceReferenceTests {
    @Test("本地文件引用默认支持随机读取")
    func localFileReference() {
        let url = URL(fileURLWithPath: "/tmp/sample.pdf")
        let reference = ResourceReference.localFile(.init(fileURL: url))
        guard case .localFile(let value) = reference else {
            Issue.record("应为本地文件引用")
            return
        }
        #expect(value.fileURL == url)
        #expect(value.supportsRandomAccess)
        #expect(reference.capabilities.contains(.rangeRead))
    }

    @Test("HTTP 引用保留请求头但不声称 Range 支持")
    func httpReference() {
        let url = URL(string: "https://example.com/video.mp4")!
        let reference = ResourceReference.remoteHTTP(
            .init(url: url, headers: ["Authorization": "Bearer test-token"])
        )
        guard case .remoteHTTP(let value) = reference else {
            Issue.record("应为 HTTP 引用")
            return
        }
        #expect(value.url == url)
        #expect(value.method == "GET")
        #expect(value.headers["Authorization"] == "Bearer test-token")
        #expect(!value.supportsRange)
        #expect(reference.capabilities.contains(.read))
        #expect(reference.capabilities.contains(.directURL))
        #expect(!reference.capabilities.contains(.rangeRead))
    }

    @Test("字节区间转换为 HTTP Range 头")
    func byteRangeHeader() {
        let range = ResourceByteRange(lowerBound: 100, upperBound: 199)
        #expect(range.length == 100)
        #expect(range.httpHeaderValue == "bytes=100-199")
    }

    @Test("字节区间按总长度收敛")
    func byteRangeClamping() {
        let range = ResourceByteRange(lowerBound: 90, upperBound: 150)
        let clamped = range.clamped(toTotalLength: 100)
        #expect(clamped?.lowerBound == 90)
        #expect(clamped?.upperBound == 99)

        let outOfBounds = ResourceByteRange(lowerBound: 200, upperBound: 300)
        #expect(outOfBounds.clamped(toTotalLength: 100) == nil)
    }
}

@Suite("资源身份、版本与缓存键")
struct ResourceIdentityRevisionTests {
    private let sourceID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    @Test("身份键使用 canonical UUID 且含多个分隔符的路径可逆")
    func identityKeyRoundTrip() throws {
        let path = try #require(ResourcePath(rawValue: "/资料/a|b|c.pdf"))
        let identity = ResourceIdentity(sourceID: sourceID, logicalPath: path)

        #expect(identity.identityKey == "v1|12345678-1234-1234-1234-123456789abc|/资料/a|b|c.pdf")
        #expect(ResourceIdentity(identityKey: identity.identityKey) == identity)
        #expect(ResourceIdentity.parse(identityKey: identity.identityKey) == identity)
    }

    @Test("身份键拒绝错误版本与非 canonical 输入")
    func identityKeyRejectsInvalidRepresentations() {
        #expect(ResourceIdentity(identityKey: "v2|12345678-1234-1234-1234-123456789abc|/a.pdf") == nil)
        #expect(ResourceIdentity(identityKey: "v1|12345678-1234-1234-1234-123456789ABC|/a.pdf") == nil)
        #expect(ResourceIdentity(identityKey: "v1|12345678-1234-1234-1234-123456789abc|//a.pdf") == nil)
        #expect(ResourceIdentity(identityKey: "v1|12345678-1234-1234-1234-123456789abc|/../a.pdf") == nil)
        #expect(ResourceIdentity(identityKey: "v1|12345678-1234-1234-1234-123456789abc") == nil)
    }

    @Test("revision 只按 ETag、服务端版本、修改时间与大小的顺序选择")
    func strongestRevisionEvidence() {
        let modifiedAt = Date(timeIntervalSince1970: 1_786_003_200)

        #expect(
            ResourceRevision.strongest(
                etag: "W/\"opaque\"",
                serverVersion: "server-2",
                modifiedAt: modifiedAt,
                byteSize: 42
            ) == .etag("W/\"opaque\"")
        )
        #expect(
            ResourceRevision.strongest(
                etag: " \n ",
                serverVersion: "server-2",
                modifiedAt: modifiedAt,
                byteSize: 42
            ) == .serverVersion("server-2")
        )
        #expect(
            ResourceRevision.strongest(
                etag: nil,
                serverVersion: " ",
                modifiedAt: modifiedAt,
                byteSize: 42
            ) == .modifiedAndSize(modifiedAt: modifiedAt, byteSize: 42)
        )
        #expect(
            ResourceRevision.strongest(
                etag: nil,
                serverVersion: nil,
                modifiedAt: modifiedAt,
                byteSize: -1
            ).isUnknown
        )
    }

    @Test("unknown revision 不能生成持久缓存键")
    func unknownRevisionRejectedByCacheKey() throws {
        let identity = ResourceIdentity(
            sourceID: sourceID,
            logicalPath: try #require(ResourcePath(rawValue: "/manual.pdf"))
        )

        #expect(
            ResourceCacheKey(
                identity: identity,
                revision: .unknown,
                variant: .content
            ) == nil
        )
        #expect(
            ResourceCacheKey(
                identity: identity,
                revision: .etag(" \n "),
                variant: .content
            ) == nil
        )
    }

    @Test("缓存键隔离内容版本、变体与字节区间")
    func cacheKeyIsolation() async throws {
        let identity = ResourceIdentity(
            sourceID: sourceID,
            logicalPath: try #require(ResourcePath(rawValue: "/manual.pdf"))
        )
        let oldRevision = ResourceRevision.etag("\"old\"")
        let newRevision = ResourceRevision.etag("\"new\"")
        let firstRange = ResourceByteRange(lowerBound: 0, upperBound: 99)
        let secondRange = ResourceByteRange(lowerBound: 100, upperBound: 199)
        let contentKey = try #require(
            ResourceCacheKey(identity: identity, revision: oldRevision, variant: .content)
        )
        let previewKey = try #require(
            ResourceCacheKey(identity: identity, revision: oldRevision, variant: .preview)
        )
        let thumbnailKey = try #require(
            ResourceCacheKey(identity: identity, revision: oldRevision, variant: .thumbnail)
        )
        let firstRangeKey = try #require(
            ResourceCacheKey(identity: identity, revision: oldRevision, variant: .byteRange(firstRange))
        )
        let secondRangeKey = try #require(
            ResourceCacheKey(identity: identity, revision: oldRevision, variant: .byteRange(secondRange))
        )
        let replacementKey = try #require(
            ResourceCacheKey(identity: identity, revision: newRevision, variant: .content)
        )

        #expect(
            Set([
                contentKey,
                previewKey,
                thumbnailKey,
                firstRangeKey,
                secondRangeKey,
                replacementKey,
            ]).count == 6
        )

        let coordinator = CacheCoordinator()
        await coordinator.setState(.offlineAvailable, for: contentKey)
        #expect(await coordinator.state(for: contentKey) == .offlineAvailable)
        #expect(await coordinator.state(for: replacementKey) == .online)
        #expect(
            !(await coordinator.setState(
                .offlineAvailable,
                for: identity,
                revision: .unknown,
                variant: .content
            ))
        )
        #expect(
            await coordinator.state(
                for: identity,
                revision: .unknown,
                variant: .content
            ) == nil
        )
    }
}

@Suite("资源元数据展示")
struct ResourceMetadataFormatterTests {
    @Test("目录与未知元数据使用明确 fallback")
    func fallbacks() {
        let folder = ResourceMetadata(isDirectory: true)
        let unknown = ResourceMetadata()

        #expect(ResourceMetadataFormatter.size(for: folder) == "文件夹")
        #expect(ResourceMetadataFormatter.modified(for: folder) == "目录")
        #expect(ResourceMetadataFormatter.size(for: unknown) == "大小未知")
        #expect(ResourceMetadataFormatter.modified(for: unknown) == "时间未知")
    }

    @Test("有效 typed metadata 由系统 Locale 格式化")
    func typedMetadataFormatting() {
        let metadata = ResourceMetadata(
            byteSize: 1_048_576,
            modifiedAt: Date(timeIntervalSinceNow: -60)
        )

        #expect(!ResourceMetadataFormatter.size(for: metadata).isEmpty)
        #expect(!ResourceMetadataFormatter.modified(for: metadata).isEmpty)
    }
}

@Suite("来源错误映射")
struct ResourceSourceErrorTests {
    @Test("URLError 映射到统一错误")
    func urlErrorMapping() {
        #expect(ResourceSourceError.mapping(URLError(.timedOut)) == .timedOut)
        #expect(ResourceSourceError.mapping(URLError(.cancelled)) == .cancelled)
        #expect(ResourceSourceError.mapping(URLError(.notConnectedToInternet)) == .networkUnavailable)
        #expect(ResourceSourceError.mapping(URLError(.cannotConnectToHost)) == .networkUnavailable)
        #expect(ResourceSourceError.mapping(URLError(.cannotFindHost)) == .networkUnavailable)
        #expect(ResourceSourceError.mapping(URLError(.userAuthenticationRequired)) == .authenticationRequired)
        #expect(ResourceSourceError.mapping(URLError(.badURL)) == .invalidReference)
    }

    @Test("Cocoa 文件错误映射到统一错误")
    func cocoaErrorMapping() {
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        #expect(ResourceSourceError.mapping(missing) == .notFound)
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(ResourceSourceError.mapping(denied) == .permissionDenied)
    }

    @Test("HTTP 状态码映射出可行动错误")
    func httpStatusMapping() {
        #expect(ResourceSourceError.http(statusCode: 401) == .authenticationRequired)
        #expect(ResourceSourceError.http(statusCode: 403) == .permissionDenied)
        #expect(ResourceSourceError.http(statusCode: 404) == .notFound)
        #expect(ResourceSourceError.http(statusCode: 500) == .httpStatus(500))
    }

    @Test("已经是统一错误时原样透传")
    func passthrough() {
        #expect(ResourceSourceError.mapping(ResourceSourceError.cancelled) == .cancelled)
    }

    @Test("可重试判断")
    func retryability() {
        #expect(ResourceSourceError.timedOut.isRetryable)
        #expect(ResourceSourceError.networkUnavailable.isRetryable)
        #expect(ResourceSourceError.httpStatus(503).isRetryable)
        #expect(!ResourceSourceError.permissionDenied.isRetryable)
        #expect(!ResourceSourceError.notFound.isRetryable)
    }

    @Test("每种错误都有面向用户的描述")
    func userDescriptions() {
        let errors: [ResourceSourceError] = [
            .authenticationRequired, .permissionDenied, .notFound, .timedOut,
            .cancelled, .httpStatus(500), .networkUnavailable, .invalidReference,
            .capabilityUnavailable, .unavailable
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
