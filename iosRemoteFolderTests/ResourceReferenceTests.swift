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
