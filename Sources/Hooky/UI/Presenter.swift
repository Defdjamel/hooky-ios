// Hooky.open() : la conversation en feuille modale (pleine hauteur sur
// iPhone, centrée sur iPad et Mac), présentée par le contrôleur le plus
// haut de la fenêtre active. Glisser vers le bas la ferme, comme le bouton ×.
import SwiftUI
import UIKit

@MainActor
final class Presenter {
    static let shared = Presenter()
    private weak var controller: UIViewController?

    func open(from presenter: UIViewController?) {
        guard let store = Hooky.shared.store else {
            assertionFailure("Hooky: call Hooky.configure(siteKey:) before Hooky.open().")
            return
        }
        if controller?.presentingViewController != nil { return }
        guard let presenter = presenter ?? Self.topViewController() else { return }
        let c = ConversationController(store: store)
        controller = c
        presenter.present(c, animated: true)
    }

    func close() {
        guard let c = controller, c.presentingViewController != nil else { return }
        c.dismiss(animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.sorted { a, _ in a.activationState == .foregroundActive }.flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

// L'hôte UIKit de la conversation ; fermée par un glissement, elle n'est plus à l'écran.
final class ConversationController: UIHostingController<AnyView> {
    private let store: ChatStore

    init(store: ChatStore) {
        self.store = store
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(ChatView(store: store, onClose: { [weak self] in self?.dismiss(animated: true) }))
        modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *), let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = 22
        }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        store.setPresented(false)
    }
}
