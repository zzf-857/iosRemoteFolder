import QuickLook
import SwiftUI
import UIKit

@MainActor
struct SystemFileFallbackView: View {
    let resource: ResourceItem
    let lease: MaterializedResourceFileLease

    @State private var showsShare = false
    @State private var showsOpenIn = false
    @State private var previewUnavailableReason: String?
    @State private var presentationError: PresentationError?

    private struct PresentationError: Identifiable {
        let id = UUID()
        let message: String
    }

    var body: some View {
        Group {
            if let previewUnavailableReason {
                ContentUnavailableView {
                    Label("系统预览不可用", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(previewUnavailableReason)
                }
            } else {
                QuickLookPreviewView(
                    lease: lease,
                    title: resource.name,
                    onUnavailable: {
                        previewUnavailableReason = "临时文件已关闭，请返回后重新打开资源"
                    }
                )
            }
        }
        .toolbar {
            if previewUnavailableReason == nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享")

                    Button {
                        showsOpenIn = true
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .accessibilityLabel("用其他 App 打开")
                }
            }
        }
        .sheet(isPresented: $showsShare) {
            ActivityView(
                lease: lease,
                onUnavailable: {
                    showsShare = false
                    presentationError = PresentationError(
                        message: "临时文件已关闭，请重新打开资源后再分享"
                    )
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsOpenIn) {
            OpenInView(
                lease: lease,
                title: resource.name,
                onUnavailable: { message in
                    presentationError = PresentationError(message: message)
                },
                onDismiss: { showsOpenIn = false }
            )
        }
        .alert(item: $presentationError) { error in
            Alert(
                title: Text("无法完成操作"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onChange(of: lease.fileURL) { _, _ in
            previewUnavailableReason = nil
            showsShare = false
            showsOpenIn = false
        }
    }
}

@MainActor
final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(fileURL: URL?, title: String?) {
        precondition(fileURL == nil || fileURL?.isFileURL == true)
        self.previewItemURL = fileURL
        self.previewItemTitle = title
    }
}

/// QLPreviewController keeps its data source weakly, so the representable's
/// coordinator owns this object for the full presentation lifetime.
@MainActor
final class QuickLookPreviewDataSource: NSObject, QLPreviewControllerDataSource {
    private var item: QuickLookPreviewItem?
    private var usageToken: MaterializedResourceFileLease.UsageToken?
    private var retiredUsageTokens: [MaterializedResourceFileLease.UsageToken] = []
    private var unavailableNotificationTask: Task<Void, Never>?

    var isAvailable: Bool {
        item != nil && usageToken != nil
    }

    init(lease: MaterializedResourceFileLease, title: String) {
        if let usageToken = lease.acquireUsage() {
            self.item = QuickLookPreviewItem(fileURL: lease.fileURL, title: title)
            self.usageToken = usageToken
        } else {
            self.item = nil
            self.usageToken = nil
        }
    }

    @discardableResult
    func update(lease: MaterializedResourceFileLease, title: String) -> Bool {
        if item?.previewItemURL == lease.fileURL, usageToken != nil {
            item = QuickLookPreviewItem(fileURL: lease.fileURL, title: title)
            unavailableNotificationTask?.cancel()
            unavailableNotificationTask = nil
            return true
        }
        guard let nextUsageToken = lease.acquireUsage() else {
            retireCurrentUsage()
            item = nil
            return false
        }
        retireCurrentUsage()
        usageToken = nextUsageToken
        item = QuickLookPreviewItem(fileURL: lease.fileURL, title: title)
        unavailableNotificationTask?.cancel()
        unavailableNotificationTask = nil
        return true
    }

    func notifyUnavailable(_ action: @escaping @MainActor () -> Void) {
        guard !isAvailable else { return }
        unavailableNotificationTask?.cancel()
        unavailableNotificationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func finish() {
        unavailableNotificationTask?.cancel()
        unavailableNotificationTask = nil
        usageToken?.release()
        usageToken = nil
        retiredUsageTokens.forEach { $0.release() }
        retiredUsageTokens.removeAll()
        item = nil
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        item == nil ? 0 : 1
    }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> any QLPreviewItem {
        precondition(index == 0)
        return item ?? QuickLookPreviewItem(fileURL: nil, title: nil)
    }

    private func retireCurrentUsage() {
        if let usageToken {
            retiredUsageTokens.append(usageToken)
            self.usageToken = nil
        }
    }
}

@MainActor
struct QuickLookPreviewView: UIViewControllerRepresentable {
    let lease: MaterializedResourceFileLease
    let title: String
    var onUnavailable: @MainActor () -> Void = {}

    func makeCoordinator() -> QuickLookPreviewDataSource {
        QuickLookPreviewDataSource(lease: lease, title: title)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        context.coordinator.notifyUnavailable(onUnavailable)
        return controller
    }

    func updateUIViewController(
        _ controller: QLPreviewController,
        context: Context
    ) {
        let isAvailable = context.coordinator.update(lease: lease, title: title)
        controller.reloadData()
        if !isAvailable {
            context.coordinator.notifyUnavailable(onUnavailable)
        }
    }

    static func dismantleUIViewController(
        _ controller: QLPreviewController,
        coordinator: QuickLookPreviewDataSource
    ) {
        controller.dataSource = nil
        coordinator.finish()
    }
}

/// Wraps a real local file URL. Its coordinator holds a usage token until the
/// activity completes or SwiftUI dismantles the controller.
@MainActor
struct ActivityView: UIViewControllerRepresentable {
    let lease: MaterializedResourceFileLease
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil
    var onUnavailable: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(lease: lease)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard let fileURL = context.coordinator.fileURL else {
            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            context.coordinator.notifyUnavailable(onUnavailable)
            return controller
        }
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { [weak coordinator] _, _, _, _ in
            Task { @MainActor in
                coordinator?.finish()
            }
        }
        controller.excludedActivityTypes = excludedActivityTypes
        Self.configurePopoverAnchor(for: controller)
        return controller
    }

    func updateUIViewController(
        _ controller: UIViewController,
        context: Context
    ) {
        guard let activityController = controller as? UIActivityViewController else {
            context.coordinator.notifyUnavailable(onUnavailable)
            return
        }
        activityController.excludedActivityTypes = excludedActivityTypes
        Self.configurePopoverAnchor(for: activityController)
    }

    static func dismantleUIViewController(
        _ controller: UIViewController,
        coordinator: Coordinator
    ) {
        (controller as? UIActivityViewController)?.completionWithItemsHandler = nil
        coordinator.finish()
    }

    @MainActor
    final class Coordinator {
        let fileURL: URL?
        private var usageToken: MaterializedResourceFileLease.UsageToken?
        private var unavailableNotificationTask: Task<Void, Never>?

        var isAvailable: Bool {
            fileURL != nil && usageToken != nil
        }

        init(lease: MaterializedResourceFileLease) {
            if let usageToken = lease.acquireUsage() {
                self.fileURL = lease.fileURL
                self.usageToken = usageToken
            } else {
                self.fileURL = nil
                self.usageToken = nil
            }
        }

        func notifyUnavailable(_ action: @escaping @MainActor () -> Void) {
            guard !isAvailable else { return }
            unavailableNotificationTask?.cancel()
            unavailableNotificationTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                action()
            }
        }

        func finish() {
            unavailableNotificationTask?.cancel()
            unavailableNotificationTask = nil
            usageToken?.release()
            usageToken = nil
        }
    }

    private static func configurePopoverAnchor(for controller: UIActivityViewController) {
        guard let popover = controller.popoverPresentationController else { return }
        let sourceView = controller.view
        sourceView?.layoutIfNeeded()
        let bounds = sourceView?.bounds ?? .zero
        popover.sourceView = sourceView
        popover.sourceRect = anchorRect(in: bounds)
        popover.permittedArrowDirections = []
    }

    private static func anchorRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.midX,
            y: bounds.midY,
            width: 1,
            height: 1
        )
    }
}

@MainActor
private final class OpenInHostViewController: UIViewController {
    var didAppear: ((OpenInHostViewController) -> Void)?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear?(self)
    }
}

/// Presents UIDocumentInteractionController's Open In menu from a concrete,
/// one-point anchor, which is valid for both compact layouts and iPad popovers.
@MainActor
struct OpenInView: UIViewControllerRepresentable {
    let lease: MaterializedResourceFileLease
    let title: String
    var onUnavailable: @MainActor (String) -> Void = { _ in }
    var onDismiss: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            lease: lease,
            title: title,
            onUnavailable: onUnavailable,
            onDismiss: onDismiss
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = OpenInHostViewController()
        let coordinator = context.coordinator
        controller.didAppear = { [weak coordinator] host in
            coordinator?.present(from: host)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.update(
            lease: lease,
            title: title,
            onUnavailable: onUnavailable,
            onDismiss: onDismiss
        )
        if controller.viewIfLoaded?.window != nil {
            context.coordinator.present(from: controller)
        }
    }

    static func dismantleUIViewController(
        _ controller: UIViewController,
        coordinator: Coordinator
    ) {
        coordinator.dismiss(animated: false, notify: false)
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor UIDocumentInteractionControllerDelegate {
        private(set) var fileURL: URL?
        private(set) var typeIdentifier: String?
        private var title: String
        private var onUnavailable: @MainActor (String) -> Void
        private var onDismiss: @MainActor () -> Void
        private var usageToken: MaterializedResourceFileLease.UsageToken?
        private weak var presentingViewController: UIViewController?
        private var presentedURL: URL?
        private var didNotifyDismissal = false
        private var isSendingToApplication = false

        /// This strong reference is required for the entire system-menu lifetime;
        /// UIDocumentInteractionController is not retained by its delegate or host.
        private(set) var documentInteractionController: UIDocumentInteractionController?

        init(
            lease: MaterializedResourceFileLease,
            title: String,
            onUnavailable: @escaping @MainActor (String) -> Void = { _ in },
            onDismiss: @escaping @MainActor () -> Void
        ) {
            if let usageToken = lease.acquireUsage() {
                self.fileURL = lease.fileURL
                self.typeIdentifier = lease.typeIdentifier
                self.usageToken = usageToken
            } else {
                self.fileURL = nil
                self.typeIdentifier = nil
                self.usageToken = nil
            }
            self.title = title
            self.onUnavailable = onUnavailable
            self.onDismiss = onDismiss
        }

        var isAvailable: Bool {
            fileURL != nil && usageToken != nil
        }

        func update(
            lease: MaterializedResourceFileLease,
            title: String,
            onUnavailable: @escaping @MainActor (String) -> Void,
            onDismiss: @escaping @MainActor () -> Void
        ) {
            self.onUnavailable = onUnavailable
            self.onDismiss = onDismiss
            guard !didNotifyDismissal else { return }
            if self.fileURL == lease.fileURL, usageToken != nil {
                self.title = title
                self.typeIdentifier = lease.typeIdentifier
                return
            }

            let nextUsageToken = lease.acquireUsage()
            dismiss(animated: false, notify: false)
            self.title = title
            if let nextUsageToken {
                self.fileURL = lease.fileURL
                self.typeIdentifier = lease.typeIdentifier
                usageToken = nextUsageToken
            } else {
                self.fileURL = nil
                self.typeIdentifier = nil
                usageToken = nil
            }
            didNotifyDismissal = false
            if nextUsageToken == nil {
                notifyUnavailableOnce("临时文件已关闭，请重新打开资源后再尝试")
            }
        }

        func present(from viewController: UIViewController) {
            presentingViewController = viewController
            guard let fileURL, usageToken != nil else {
                notifyUnavailableOnce("临时文件已关闭，请重新打开资源后再尝试")
                return
            }
            guard !didNotifyDismissal,
                  presentedURL != fileURL,
                  documentInteractionController == nil,
                  let sourceView = viewController.viewIfLoaded,
                  sourceView.window != nil else {
                return
            }

            sourceView.layoutIfNeeded()
            let interactionController = UIDocumentInteractionController(url: fileURL)
            interactionController.name = title
            interactionController.uti = typeIdentifier
            interactionController.delegate = self
            documentInteractionController = interactionController

            let bounds = sourceView.bounds
            let anchor = CGRect(
                x: bounds.midX,
                y: bounds.midY,
                width: 1,
                height: 1
            )
            if interactionController.presentOpenInMenu(
                from: anchor,
                in: sourceView,
                animated: true
            ) {
                presentedURL = fileURL
            } else {
                interactionController.delegate = nil
                documentInteractionController = nil
                finishUsage()
                notifyUnavailableOnce("未找到可打开此文件的 App")
            }
        }

        func dismiss(animated: Bool, notify: Bool) {
            documentInteractionController?.dismissMenu(animated: animated)
            documentInteractionController?.delegate = nil
            documentInteractionController = nil
            presentedURL = nil
            isSendingToApplication = false
            finishUsage()
            if notify {
                notifyDismissalOnce()
            }
        }

        func documentInteractionController(
            _ controller: UIDocumentInteractionController,
            willBeginSendingToApplication application: String?
        ) {
            guard controller === documentInteractionController else { return }
            isSendingToApplication = true
        }

        func documentInteractionController(
            _ controller: UIDocumentInteractionController,
            didEndSendingToApplication application: String?
        ) {
            guard controller === documentInteractionController else { return }
            isSendingToApplication = false
            controller.delegate = nil
            documentInteractionController = nil
            presentedURL = nil
            finishUsage()
            notifyDismissalOnce()
        }

        func documentInteractionControllerDidDismissOpenInMenu(
            _ controller: UIDocumentInteractionController
        ) {
            guard controller === documentInteractionController else { return }
            presentedURL = nil
            guard !isSendingToApplication else { return }
            controller.delegate = nil
            documentInteractionController = nil
            finishUsage()
            notifyDismissalOnce()
        }

        func documentInteractionControllerViewControllerForPreview(
            _ controller: UIDocumentInteractionController
        ) -> UIViewController {
            presentingViewController ?? UIViewController()
        }

        func documentInteractionControllerViewForPreview(
            _ controller: UIDocumentInteractionController
        ) -> UIView? {
            presentingViewController?.viewIfLoaded
        }

        func documentInteractionControllerRectForPreview(
            _ controller: UIDocumentInteractionController
        ) -> CGRect {
            presentingViewController?.viewIfLoaded?.bounds ?? .zero
        }

        private func notifyDismissalOnce() {
            guard !didNotifyDismissal else { return }
            didNotifyDismissal = true
            let onDismiss = self.onDismiss
            Task { @MainActor in
                await Task.yield()
                onDismiss()
            }
        }

        private func notifyUnavailableOnce(_ message: String) {
            guard !didNotifyDismissal else { return }
            didNotifyDismissal = true
            let onUnavailable = self.onUnavailable
            let onDismiss = self.onDismiss
            Task { @MainActor in
                await Task.yield()
                onUnavailable(message)
                onDismiss()
            }
        }

        private func finishUsage() {
            usageToken?.release()
            usageToken = nil
        }
    }
}
