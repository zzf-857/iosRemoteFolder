import Foundation

/// Presentation-only formatting for typed resource metadata.
///
/// Adapters and domain values remain locale-neutral. The system locale decides
/// both the byte-count and relative-date wording at the point of display.
enum ResourceMetadataFormatter {
    static func size(for metadata: ResourceMetadata) -> String {
        guard !metadata.isDirectory else { return "文件夹" }
        guard let byteSize = metadata.byteSize, byteSize >= 0 else {
            return "大小未知"
        }

        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    static func modified(for metadata: ResourceMetadata) -> String {
        guard !metadata.isDirectory else { return "目录" }
        guard let modifiedAt = metadata.modifiedAt else {
            return "时间未知"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .short
        return formatter.localizedString(for: modifiedAt, relativeTo: Date())
    }
}
