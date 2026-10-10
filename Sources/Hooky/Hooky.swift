// L'API publique du SDK : les mêmes noms que sur Android et que la bulle web.
//
//   Hooky.configure(siteKey: "…")          // au lancement (translation: false : sans traduction)
//   Hooky.identify(name: "Lila", email: "lila@exemple.fr", userId: "42", attributes: ["plan": "Pro"])
//   Hooky.setAttributes(["panier": 49.9])  // données libres, fusionnées
//   ContentView().hookyBubble()             // le bouton flottant
//   Hooky.open() / Hooky.close()
//   Hooky.track("signup") / Hooky.track("order", value: 49)
//   Hooky.reset()                           // déconnexion de l'utilisateur
//   Hooky.shared.unreadCount                // @Published, en direct
import Foundation
import Combine
import SwiftUI
import UIKit

/// The Hooky chat SDK: a native conversation between your users and your team.
///
/// ```swift
/// Hooky.configure(siteKey: "YOUR_PUBLIC_SITE_KEY")
/// ContentView().hookyBubble()
/// ```
@MainActor
public final class Hooky: ObservableObject {
    /// The shared instance, observable from SwiftUI (`@ObservedObject var hooky = Hooky.shared`).
    public static let shared = Hooky()

    /// The SDK version, sent to the server in the `X-Hooky-Client` header.
    public nonisolated static let version = SDKInfo.version

    /// Unread messages from the team, updated live.
    @Published public private(set) var unreadCount = 0
    /// The site's name, once its appearance is loaded.
    @Published public private(set) var siteName: String?
    /// Whether the conversation is on screen.
    @Published public private(set) var isOpen = false
    /// Whether `configure(siteKey:)` has been called.
    @Published public private(set) var isConfigured = false

    // L'apparence du site, pour la bulle.
    @Published private(set) var site: WidgetSite?

    private(set) var store: ChatStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var unreadContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    /// Called on the main thread whenever `unreadCount` changes.
    public var onUnreadCountChange: ((Int) -> Void)?

    private init() {}

    // MARK: - Configuration

    /// Starts the SDK. Call it once at launch, before anything else.
    ///
    /// Loads the site's appearance, resumes the saved conversation (if any) and opens the live connection.
    /// - Parameters:
    ///   - siteKey: the site's public key (Hooky › Sites › Install).
    ///   - apiURL: the API address, for local tests (default `https://api.heyhooky.com`).
    ///   - language: forces the interface language (`fr`, `en`, `es`, `pt`, `it`, `de`); the device language otherwise.
    ///   - translation: offers to translate the team's messages written in another language than the interface's
    ///     (a “Translate” link under them, and “Always translate” in the conversation's menu). On by default.
    public static func configure(siteKey: String, apiURL: URL? = nil, language: String? = nil, translation: Bool = true) {
        shared.configure(siteKey: siteKey, apiURL: apiURL, language: language, translation: translation,
                         tokenStore: KeychainTokenStore(), defaults: .standard)
    }

    func configure(siteKey: String, apiURL: URL?, language: String?, translation: Bool = true, tokenStore: TokenStoring,
                   defaults: UserDefaults, session: URLSession = .shared, observeLifecycle: Bool = true,
                   makeCable: (@MainActor (URL, String) -> ConversationCable)? = nil) {
        let key = siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = apiURL ?? HookyAPI.defaultBaseURL
        let texts = Texts(language: Texts.language(forced: language))
        if let store, store.siteKey == key, store.api.baseURL == base, store.texts.language == texts.language {
            store.translationEnabled = translation
            return
        }
        let previous = store
        store?.tearDown()
        subscriptions = []
        let api = HookyAPI(baseURL: base, siteKey: key, session: session)
        let s = ChatStore(siteKey: key, api: api, texts: texts, tokenStore: tokenStore, defaults: defaults,
                          makeCable: makeCable, observeLifecycle: observeLifecycle, translation: translation)
        // Ce que l'app a dit du visiteur suit le changement de configuration.
        if let previous {
            s.identify(name: previous.identity?.name, email: previous.identity?.email, userID: previous.userID,
                       attributes: previous.attributes.mapValues { $0 })
        }
        store = s
        Tracker.shared.configure(api)
        s.$unreadCount.removeDuplicates().sink { [weak self] n in self?.unreadChanged(n) }.store(in: &subscriptions)
        s.$site.sink { [weak self] site in
            self?.site = site
            self?.siteName = site?.name
        }.store(in: &subscriptions)
        s.$isPresented.sink { [weak self] p in self?.isOpen = p }.store(in: &subscriptions)
        isConfigured = true
        s.start()
    }

    /// Tells Hooky who the user is. Optional, never throws.
    ///
    /// Sent with the first message, or right away (grouped, within a second) when a conversation already exists;
    /// retried at the next message if the device is offline. With an email, the chat skips its name and email form.
    ///
    /// ```swift
    /// Hooky.identify(name: "Lila", email: "lila@example.com", userId: "42", attributes: ["plan": "Pro"])
    /// ```
    /// - Parameters:
    ///   - name: the user's first name; replaces the conversation's. `nil` clears it on this device.
    ///   - email: the user's email; replaces the conversation's. `nil` clears it on this device.
    ///   - userId: your own identifier for the user (shown to your team, not verified). `nil` leaves it unchanged.
    ///     A different `userId` than the current conversation's starts a new conversation, like `reset()`:
    ///     another account on the same device never sees the previous one's thread.
    ///   - attributes: free data shown to your team, merged with the previous ones (strings, numbers, booleans;
    ///     `nil` removes a key). Up to 50 keys.
    public static func identify(name: String? = nil, email: String? = nil, userId: String? = nil,
                                attributes: [String: HookyValue?] = [:]) {
        guard let store = shared.store else {
            assertionFailure("Hooky: call Hooky.configure(siteKey:) before Hooky.identify().")
            return
        }
        if store.identify(name: name, email: email, userID: userId, attributes: attributes) {
            Presenter.shared.close()
        }
    }

    /// Adds free data about the user, shown to your team next to the conversation: `["plan": "Pro", "cart": 49.9]`.
    ///
    /// Merged with the previous data (`nil` removes a key). Sent with the first message, or right away (grouped,
    /// within a second) when a conversation already exists. Never throws.
    public static func setAttributes(_ attributes: [String: HookyValue?]) {
        guard let store = shared.store else {
            assertionFailure("Hooky: call Hooky.configure(siteKey:) before Hooky.setAttributes().")
            return
        }
        store.setAttributes(attributes)
    }

    // MARK: - Ouvrir, fermer

    /// Opens the conversation full screen, over the app's top-most view controller.
    public static func open() {
        Presenter.shared.open(from: nil)
    }

    /// Opens the conversation, presented by the given view controller (UIKit).
    public static func open(from viewController: UIViewController) {
        Presenter.shared.open(from: viewController)
    }

    /// Closes the conversation if it is open.
    public static func close() {
        Presenter.shared.close()
    }

    // MARK: - Stats

    /// Sends an event to the site's stats (like `Hooky.track` on the web). Never throws, can be called from any thread,
    /// even before `configure` (the event then waits for it).
    /// - Parameters:
    ///   - name: the event name (`"signup"`, `"order"`…).
    ///   - value: an optional amount (`49.9`).
    ///   - properties: optional flat properties (strings, numbers, booleans).
    public nonisolated static func track(_ name: String, value: Double? = nil, properties: [String: HookyValue] = [:]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Tracker.shared.send(TrackedEvent(name: trimmed, value: value, properties: properties))
    }

    // MARK: - Déconnexion

    /// Forgets the conversation, the identity and the draft (call it when the app's user logs out).
    public static func reset() {
        Presenter.shared.close()
        shared.store?.forget(clearIdentity: true)
    }

    // MARK: - Non-lus

    /// Unread messages from the team (same as `Hooky.shared.unreadCount`).
    public static var unreadCount: Int { shared.unreadCount }

    /// The unread count, now and at every change.
    public static func unreadCountUpdates() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(shared.unreadCount)
            shared.unreadContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in shared.unreadContinuations[id] = nil }
            }
        }
    }

    private func unreadChanged(_ n: Int) {
        guard n != unreadCount else { return }
        unreadCount = n
        onUnreadCountChange?(n)
        for c in unreadContinuations.values { c.yield(n) }
    }

    // Pour les tests : repartir de zéro.
    func tearDownForTests() {
        store?.tearDown()
        store = nil
        subscriptions = []
        site = nil
        siteName = nil
        unreadCount = 0
        isConfigured = false
    }
}

// MARK: - Pour les surcouches du SDK

// Ce dont le plugin Flutter a besoin et que l'API publique ne montre pas :
// se présenter au serveur sous son propre nom, et lire l'apparence du site
// pour dessiner sa bulle. Réservé aux surcouches de Hooky :
//   @_spi(HookyWrapper) import Hooky
@_spi(HookyWrapper)
public extension Hooky {
    /// The `X-Hooky-Client` value (`hooky-flutter/1.0.0`…), set before `configure`; `nil` for the default `hooky-ios/<version>`.
    nonisolated static var clientName: String? {
        get { SDKInfo.clientOverride.value }
        set { SDKInfo.clientOverride.value = newValue }
    }

    /// The site's color (`#RRGGBB`), once its appearance is loaded.
    var siteColor: String? { site?.color }

    /// The side of the screen set for the site's bubble (`left` or `right`).
    var sitePosition: String? { site?.position }
}

// Les événements de stats : envoyés hors du fil principal, mis de côté (100
// au plus) tant que configure n'a pas été appelé.
final class Tracker: @unchecked Sendable {
    static let shared = Tracker()
    private let lock = NSLock()
    private var api: HookyAPI?
    private var waiting: [TrackedEvent] = []

    func configure(_ api: HookyAPI) {
        lock.lock()
        self.api = api
        let queued = waiting
        waiting = []
        lock.unlock()
        for e in queued { post(e, api) }
    }

    func send(_ event: TrackedEvent) {
        lock.lock()
        guard let api else {
            if waiting.count < 100 { waiting.append(event) }
            lock.unlock()
            return
        }
        lock.unlock()
        post(event, api)
    }

    private func post(_ event: TrackedEvent, _ api: HookyAPI) {
        Task.detached(priority: .utility) { try? await api.track(event) }
    }
}
