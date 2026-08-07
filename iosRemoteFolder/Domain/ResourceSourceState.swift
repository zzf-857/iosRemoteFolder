import Foundation

/// 来源的连接生命周期状态，供 Sources 页面展示与重试入口使用。
///
/// 该状态由 `SourcesStore` 汇总 adapter 的异步结果得到；UI 只消费状态，
/// 不直接调用 URLSession 或 FileManager。
enum ResourceSourceState: Hashable, Sendable {
    /// 尚未建立连接，或已被用户/系统断开。
    case disconnected
    /// 正在探测、认证或列举，UI 应显示进行中反馈。
    case connecting
    /// 连接成功，可以列举与读取资源。
    case ready
    /// 连接失败，携带可行动的错误说明，UI 应提供重试入口。
    case failed(ResourceSourceError)

    /// 是否允许用户触发（重）连接。
    var canConnect: Bool {
        switch self {
        case .connecting, .ready:
            return false
        case .disconnected, .failed:
            return true
        }
    }

    /// 面向用户的状态标题。
    var title: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .ready: return "已连接"
        case .failed: return "连接失败"
        }
    }
}
