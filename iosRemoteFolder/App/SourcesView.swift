import SwiftUI
import UniformTypeIdentifiers

private struct RemoteSourceDraft: Identifiable {
    let id: UUID
    let sourceID: UUID?
    let name: String
    let endpoint: String
    let kind: ResourceSource.SourceKind
    let username: String
    let password: String

    static func adding() -> Self {
        Self(
            id: UUID(),
            sourceID: nil,
            name: "",
            endpoint: "",
            kind: .webdav,
            username: "",
            password: ""
        )
    }

    static func editing(_ source: ResourceSource) -> Self {
        Self(
            id: source.id,
            sourceID: source.id,
            name: source.name,
            endpoint: source.endpoint,
            kind: source.kind,
            username: "",
            password: ""
        )
    }
}

private struct LocalSourceDraft: Identifiable {
    let id: UUID
    let sourceID: UUID
    let name: String
}

struct SourcesView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isShowingFolderImporter = false
    @State private var remoteDraft: RemoteSourceDraft?
    @State private var localDraft: LocalSourceDraft?
    @State private var reauthorizationSourceID: UUID?
    @State private var pendingAction: SourceAction?

    private var store: SourcesStore { appModel.sourcesStore }

    private enum SourceAction: Hashable {
        case add(URL)
        case reauthorize(UUID, URL)
        case remove(UUID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AddSourceRow(
                        title: "添加本地文件夹",
                        subtitle: "从文件 App 选择一个文件夹",
                        systemImage: "folder.badge.plus"
                    ) {
                        appModel.dismissSourceError()
                        reauthorizationSourceID = nil
                        isShowingFolderImporter = true
                    }

                    AddSourceRow(
                        title: "添加 WebDAV / Alist",
                        subtitle: "连接你的服务器或网盘挂载",
                        systemImage: "server.rack"
                    ) {
                        appModel.dismissSourceError()
                        remoteDraft = .adding()
                    }
                }

                if let error = appModel.sourceActionError {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("来源操作失败", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.headline)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("关闭") {
                                appModel.dismissSourceError()
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("我的来源") {
                    if store.entries.isEmpty {
                        ContentUnavailableView {
                            Label("还没有来源", systemImage: "externaldrive.badge.plus")
                        } description: {
                            Text("从上方添加你的 Alist、WebDAV 或本地文件夹。")
                        }
                    } else {
                        ForEach(store.entries) { entry in
                            SourceConnectionRow(
                                entry: entry,
                                retry: { store.retry(entry.id) },
                                edit: appModel.isManagedSource(entry.id) ? {
                                    beginEditing(entry)
                                } : nil,
                                reauthorize: canReauthorize(entry) ? {
                                    appModel.dismissSourceError()
                                    reauthorizationSourceID = entry.id
                                    isShowingFolderImporter = true
                                } : nil,
                                remove: appModel.isManagedSource(entry.id) ? {
                                    pendingAction = .remove(entry.id)
                                } : nil
                            )
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .ambientScreenBackground()
            .navigationTitle("来源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发现局域网", systemImage: "dot.radiowaves.left.and.right") {}
                }
            }
            .glassNavigationBar()
            .fileImporter(
                isPresented: $isShowingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderImportResult(result)
            }
            .sheet(item: $remoteDraft) { draft in
                RemoteSourceFormView(draft: draft) { sourceID, name, endpoint, kind, username, password in
                    remoteDraft = nil
                    if let sourceID {
                        appModel.editRemoteSource(
                            sourceID: sourceID,
                            name: name,
                            endpoint: endpoint,
                            kind: kind,
                            username: username,
                            password: password
                        )
                    } else {
                        appModel.addRemoteSource(
                            name: name,
                            endpoint: endpoint,
                            kind: kind,
                            username: username,
                            password: password
                        )
                    }
                }
            }
            .sheet(item: $localDraft) { draft in
                LocalSourceFormView(draft: draft) { name in
                    localDraft = nil
                    appModel.editLocalSource(sourceID: draft.sourceID, displayName: name)
                } changeFolder: {
                    localDraft = nil
                    reauthorizationSourceID = draft.sourceID
                    isShowingFolderImporter = true
                }
            }
            .task {
                store.connectAll()
            }
            .task(id: pendingAction) {
                guard let pendingAction else { return }
                defer { self.pendingAction = nil }
                switch pendingAction {
                case .add(let url):
                    appModel.addLocalSource(directoryURL: url)
                case .reauthorize(let sourceID, let url):
                    appModel.reauthorizeLocalSource(sourceID: sourceID, directoryURL: url)
                case .remove(let sourceID):
                    appModel.removeManagedSource(sourceID: sourceID)
                }
            }
        }
    }

    private func beginEditing(_ entry: SourcesStore.Entry) {
        appModel.dismissSourceError()
        switch entry.source.kind {
        case .local:
            localDraft = LocalSourceDraft(
                id: entry.id,
                sourceID: entry.id,
                name: entry.source.name
            )
        case .webdav, .alist:
            remoteDraft = .editing(entry.source)
        case .lan, .http:
            break
        }
    }

    private func canReauthorize(_ entry: SourcesStore.Entry) -> Bool {
        guard appModel.isManagedLocalSource(entry.id),
              case .failed(let error) = entry.state else {
            return false
        }
        switch error {
        case .authorizationRequired, .invalidReference, .permissionDenied, .notFound:
            return true
        default:
            return false
        }
    }

    private func handleFolderImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            appModel.dismissSourceError()
            guard let url = urls.first else {
                appModel.sourceActionError = ResourceSourceError.invalidReference.localizedDescription
                reauthorizationSourceID = nil
                return
            }
            if let sourceID = reauthorizationSourceID {
                pendingAction = .reauthorize(sourceID, url)
            } else {
                pendingAction = .add(url)
            }
            reauthorizationSourceID = nil
        case .failure(let error):
            reauthorizationSourceID = nil
            guard !Self.isUserCancellation(error) else {
                appModel.dismissSourceError()
                return
            }
            appModel.sourceActionError = ResourceSourceError.mapping(error).localizedDescription
        }
    }

    private static func isUserCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }
}

/// Pure validation kept outside the view so the UI security boundary has
/// deterministic coverage without exposing the form's transient password state.
enum RemoteSourceFormValidation {
    static func canSubmit(
        name: String,
        endpoint: String,
        username: String,
        password: String
    ) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpointURL = validEndpointURL(endpoint) else {
            return false
        }
        return RemoteSourceTransportPolicy.permitsCredentials(
            endpoint: endpointURL,
            hasCredentials: hasCredentials(username: username, password: password)
        )
    }

    static func hasInsecureCredentialTransport(
        endpoint: String,
        username: String,
        password: String
    ) -> Bool {
        guard let endpointURL = validEndpointURL(endpoint),
              endpointURL.scheme?.lowercased() == "http" else {
            return false
        }
        return hasCredentials(username: username, password: password)
    }

    private static func validEndpointURL(_ endpoint: String) -> URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    private static func hasCredentials(username: String, password: String) -> Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !password.isEmpty
    }
}

/// Temporary WebDAV/Alist source form. The password is passed directly to the
/// composition root and is not stored in view state beyond this presentation.
private struct RemoteSourceFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var endpoint: String
    @State private var username: String
    @State private var password: String
    @State private var kind: ResourceSource.SourceKind

    let draft: RemoteSourceDraft
    let submit: (UUID?, String, String, ResourceSource.SourceKind, String, String) -> Void

    init(
        draft: RemoteSourceDraft,
        submit: @escaping (UUID?, String, String, ResourceSource.SourceKind, String, String) -> Void
    ) {
        self.draft = draft
        self.submit = submit
        _name = State(initialValue: draft.name)
        _endpoint = State(initialValue: draft.endpoint)
        _kind = State(initialValue: draft.kind)
        _username = State(initialValue: draft.username)
        _password = State(initialValue: draft.password)
    }

    private var canSubmit: Bool {
        RemoteSourceFormValidation.canSubmit(
            name: name,
            endpoint: endpoint,
            username: username,
            password: password
        )
    }

    private var hasInsecureCredentialTransport: Bool {
        RemoteSourceFormValidation.hasInsecureCredentialTransport(
            endpoint: endpoint,
            username: username,
            password: password
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("来源类型") {
                    Picker("协议", selection: $kind) {
                        Text("WebDAV").tag(ResourceSource.SourceKind.webdav)
                        Text("Alist / OpenList").tag(ResourceSource.SourceKind.alist)
                    }
                    .pickerStyle(.segmented)
                }

                Section("连接") {
                    TextField("名称", text: $name)
                        .textContentType(.organizationName)
                    TextField("WebDAV 地址", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("例如 https://example.com/dav/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("优先使用 HTTPS；HTTP 仅用于你明确信任的局域网服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if kind == .alist {
                        Text("请为 Alist 创建限制在目标目录的只读账户，不要在应用中使用管理员账户。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("认证（可选）") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    if hasInsecureCredentialTransport {
                        Label(
                            ResourceSourceError.insecureCredentialTransport.localizedDescription,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if draft.sourceID != nil {
                        Text("留空以保留当前凭证；填写任一字段会替换当前凭证。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle(draft.sourceID == nil ? "添加远端来源" : "编辑远端来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.sourceID == nil ? "连接" : "保存") {
                        submit(
                            draft.sourceID,
                            name.trimmingCharacters(in: .whitespacesAndNewlines),
                            endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                            kind,
                            username,
                            password
                        )
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}

private struct LocalSourceFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    let draft: LocalSourceDraft
    let save: (String) -> Void
    let changeFolder: () -> Void

    init(
        draft: LocalSourceDraft,
        save: @escaping (String) -> Void,
        changeFolder: @escaping () -> Void
    ) {
        self.draft = draft
        self.save = save
        self.changeFolder = changeFolder
        _name = State(initialValue: draft.name)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("来源") {
                    TextField("名称", text: $name)
                        .textContentType(.organizationName)
                    Text("Files 文件夹")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        changeFolder()
                        dismiss()
                    } label: {
                        Label("更换文件夹", systemImage: "folder.badge.gearshape")
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    Text("更换后会保留当前来源 ID，并重新连接新文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("编辑本地来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

/// 添加来源入口行：品牌渐变 tile + 标题/副标题。
private struct AddSourceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        AppTheme.brandGradient,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fontDesign(.rounded)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}

/// 来源连接行：复用 `SourceRowView` 的身份与状态展示，再按实时连接状态
/// 附加连接中、失败原因、重试和重新授权入口。UI 只消费 `SourcesStore` 的状态。
private struct SourceConnectionRow: View {
    let entry: SourcesStore.Entry
    let retry: () -> Void
    let edit: (() -> Void)?
    let reauthorize: (() -> Void)?
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                SourceRowView(source: displaySource)
                if edit != nil || remove != nil || reauthorize != nil {
                    managementMenu
                }
            }

            switch entry.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在连接…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44, alignment: .leading)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reauthorize {
                        Button(action: reauthorize) {
                            Label("重新授权", systemImage: "folder.badge.gearshape")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)
                        .frame(minHeight: 44)
                    } else {
                        Button(action: retry) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.accent)
                        .frame(minHeight: 44)
                    }
                }
            case .disconnected where !entry.hasAdapter:
                Text("适配器开发中，即将支持")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
            case .disconnected, .ready:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let edit {
                Button(action: edit) {
                    Label("编辑来源", systemImage: "pencil")
                }
                .tint(AppTheme.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let remove {
                Button(role: .destructive, action: remove) {
                    Label("移除来源", systemImage: "trash")
                }
            }
        }
    }

    /// 可见的管理入口：滑动操作保留，但不再是唯一路径。
    private var managementMenu: some View {
        Menu {
            if let edit {
                Button(action: edit) {
                    Label("编辑来源", systemImage: "pencil")
                }
            }
            if let reauthorize {
                Button(action: reauthorize) {
                    Label("重新授权", systemImage: "folder.badge.gearshape")
                }
            }
            if case .failed = entry.state {
                Button(action: retry) {
                    Label("重试连接", systemImage: "arrow.clockwise")
                }
            }
            if let remove {
                Divider()
                Button(role: .destructive, action: remove) {
                    Label("移除来源", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("管理来源 \(entry.source.name)"))
    }

    private var displaySource: ResourceSource {
        var source = entry.source
        switch entry.state {
        case .disconnected:
            source.status = .disconnected
        case .connecting:
            source.status = .connecting
        case .ready:
            source.status = .connected
        case .failed:
            source.status = .needsAttention
        }
        return source
    }
}
