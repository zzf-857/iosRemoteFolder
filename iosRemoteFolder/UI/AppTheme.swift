import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.08, green: 0.61, blue: 0.55)
    static let secondaryAccent = Color(red: 0.22, green: 0.42, blue: 0.78)
    static let warmAccent = Color(red: 0.95, green: 0.47, blue: 0.18)
}

struct GlassSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect()
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

