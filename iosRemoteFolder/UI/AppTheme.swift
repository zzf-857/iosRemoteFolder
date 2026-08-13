import SwiftUI

/// 视觉语言 v2（D-060）：类型光谱渐变 + 玻璃卡片。
///
/// 令牌层只描述颜色、渐变与卡片材质；无障碍语义、布局双形态与
/// Reduce Motion 约束由各视图维持，不因视觉刷新回退。
enum AppTheme {
    /// 主色：高饱和靛紫，深色模式提亮以保持对比。
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.52, blue: 1.00, alpha: 1)
            : UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 1)
    })

    static let secondaryAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.72, blue: 1.00, alpha: 1)
            : UIColor(red: 0.16, green: 0.52, blue: 0.97, alpha: 1)
    })

    static let warmAccent = Color(red: 0.98, green: 0.52, blue: 0.24)

    /// 品牌渐变：用于来源图标与强调按钮。
    static let brandGradient = LinearGradient(
        colors: [accent, secondaryAccent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 连接状态色。
    static func statusColor(for status: ResourceSource.SourceStatus) -> Color {
        switch status {
        case .connected: Color(red: 0.20, green: 0.78, blue: 0.47)
        case .connecting, .indexing: secondaryAccent
        case .needsAttention: warmAccent
        case .disconnected, .localOnly: Color(uiColor: .systemGray)
        }
    }
}

extension ResourceKind {
    /// 类型光谱：每种资源类型的双色渐变，是 v2 的核心视觉锚点。
    /// 颜色保持足够深度，保证白色符号的对比度。
    var gradientColors: [Color] {
        switch self {
        case .folder:
            [Color(red: 0.36, green: 0.38, blue: 0.98), Color(red: 0.18, green: 0.58, blue: 0.98)]
        case .pdf:
            [Color(red: 0.99, green: 0.44, blue: 0.28), Color(red: 0.92, green: 0.22, blue: 0.42)]
        case .markdown:
            [Color(red: 0.10, green: 0.70, blue: 0.54), Color(red: 0.08, green: 0.53, blue: 0.78)]
        case .text:
            [Color(red: 0.22, green: 0.53, blue: 0.97), Color(red: 0.16, green: 0.72, blue: 0.88)]
        case .image:
            [Color(red: 0.56, green: 0.34, blue: 0.96), Color(red: 0.34, green: 0.41, blue: 0.98)]
        case .video:
            [Color(red: 0.64, green: 0.29, blue: 0.93), Color(red: 0.93, green: 0.28, blue: 0.60)]
        case .audio:
            [Color(red: 0.96, green: 0.32, blue: 0.53), Color(red: 0.98, green: 0.53, blue: 0.26)]
        case .unknown:
            [Color(red: 0.47, green: 0.51, blue: 0.60), Color(red: 0.33, green: 0.36, blue: 0.44)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    /// v2 玻璃卡片：连续圆角 + 超薄材质 + 细描边 + 柔和投影。
    func modernCard(cornerRadius: CGFloat = 24) -> some View {
        self
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 7)
    }

    /// 顶层页面的内容层环境背景：分组底色上叠加主色微光斑。
    func ambientScreenBackground() -> some View {
        background(AmbientBackground().ignoresSafeArea())
    }

    /// 将导航栏背景设置为 iOS 26 Liquid Glass，旧系统回退到 `ultraThinMaterial`。
    @ViewBuilder
    func glassNavigationBar() -> some View {
        if #available(iOS 26.0, *) {
            self
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// 将标签栏背景设置为 iOS 26 Liquid Glass，旧系统回退到 `ultraThinMaterial`。
    @ViewBuilder
    func glassTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self
                .toolbarBackground(.visible, for: .tabBar)
        } else {
            self
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

/// 内容层环境背景：极轻的主色光斑，深浅色自适应，不参与交互。
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(
                colors: [AppTheme.accent.opacity(0.16), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 480
            )
            RadialGradient(
                colors: [AppTheme.secondaryAccent.opacity(0.10), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 520
            )
        }
        .accessibilityHidden(true)
    }
}
