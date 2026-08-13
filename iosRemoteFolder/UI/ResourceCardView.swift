import SwiftUI

/// 视觉语言 v2 共享组件（D-060）。
/// 本文件历史上承载未接线的 ResourceCardView；v2 起改为组件库，
/// 文件名保留以避免调整工程引用。

/// 渐变图标 tile：白色符号 + 类型光谱渐变底，全应用统一的视觉锚点。
struct ResourceIconTile: View {
    let kind: ResourceKind
    var side: CGFloat = 40

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(
                kind.gradient,
                in: RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
            )
            .shadow(
                color: (kind.gradientColors.first ?? .clear).opacity(0.32),
                radius: side * 0.14,
                x: 0,
                y: side * 0.06
            )
            .accessibilityHidden(true)
    }
}

/// 来源图标 tile：品牌渐变底 + 白色协议符号。
struct SourceIconTile: View {
    let kind: ResourceSource.SourceKind
    var side: CGFloat = 44

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(
                AppTheme.brandGradient,
                in: RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
            )
            .shadow(color: AppTheme.accent.opacity(0.30), radius: side * 0.14, x: 0, y: side * 0.06)
            .accessibilityHidden(true)
    }
}

/// 状态胶囊：彩色圆点 + 轻底色，替代裸文本状态。
struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// v2 区块标题：SF Pro Rounded 展示层级。
struct ModernSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.bold())
                .fontDesign(.rounded)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
