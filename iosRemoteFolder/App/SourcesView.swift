import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: {}) {
                        Label("添加来源", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                    .tint(AppTheme.accent)
                }

                Section("我的来源") {
                    ForEach(appModel.sources) { source in
                        SourceRowView(source: source)
                    }
                }
            }
            .navigationTitle("来源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发现局域网", systemImage: "dot.radiowaves.left.and.right") {}
                }
            }
        }
    }
}

