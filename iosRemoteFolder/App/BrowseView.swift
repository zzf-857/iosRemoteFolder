import SwiftUI

struct BrowseView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            ScrollView {
                Picker("资源类型", selection: $appModel.selectedKind) {
                    Text("全部").tag(ResourceKind?.none)
                    Text("文档").tag(ResourceKind?.some(.pdf))
                    Text("图片").tag(ResourceKind?.some(.image))
                    Text("视频").tag(ResourceKind?.some(.video))
                    Text("音乐").tag(ResourceKind?.some(.audio))
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 16)], spacing: 22) {
                    ForEach(appModel.filteredResources) { resource in
                        NavigationLink(value: resource) {
                            ResourceCardView(resource: resource)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("浏览")
            .searchable(text: $appModel.searchText, prompt: "搜索资源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("名称", systemImage: "textformat") {}
                        Button("最近打开", systemImage: "clock") {}
                        Button("大小", systemImage: "arrow.up.arrow.down") {}
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
            .navigationDestination(for: ResourceItem.self) { resource in
                ResourceViewerHost(resource: resource)
            }
        }
    }
}

