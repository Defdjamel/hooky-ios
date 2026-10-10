// L'état de la bulle et sa logique, comme le cœur de widget/widget.js :
// l'apparence du site, le jeton (trousseau), le fil, l'envoi (texte et
// fichiers, avec progression, le message déjà affiché, estompé), le temps
// réel, « Lu », « … écrit », les non-lus, le brouillon gardé.
//
// Un seul ChatStore par clé de site, tenu par Hooky.shared : il survit à la
// fermeture de la conversation (le brouillon, les fichiers choisis et la
// position dans le fil restent).
import Foundation
import UIKit
import Combine
import os

@MainActor
final class ChatStore: ObservableObject {
    // Le message en route : affiché tout de suite, estompé, avec la
    // progression de ses fichiers.
    struct Pending: Equatable {
        var body: String
        var files: [OutgoingFile]
        var progress: Double?
        var startedAt: Date
        // Les photos, lues une fois sur le disque.
        var previews: [UIImage] = []
    }

    let siteKey: String
    let texts: Texts
    let api: HookyAPI

    @Published private(set) var site: WidgetSite?
    @Published private(set) var token: String?
    @Published private(set) var conversation: VisitorConversation?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var teamTypingName: String?
    @Published private(set) var teamReadAt: Date?
    @Published private(set) var pending: Pending?
    @Published var error: String?
    @Published private(set) var unreadCount = 0
    // La conversation est à l'écran (et l'app au premier plan) : les
    // messages de l'équipe sont lus aussitôt.
    @Published private(set) var isPresented = false
    // Ce qui est en train d'être écrit, gardé d'une ouverture à l'autre (et
    // d'un lancement à l'autre pour le texte).
    @Published var draft = "" { didSet { draftChanged(oldValue) } }
    @Published private(set) var attachments: [OutgoingFile] = []
    @Published private(set) var preparing = 0
    // Le formulaire d'une nouvelle conversation (si l'app n'a pas appelé identify).
    @Published var formName = ""
    @Published var formEmail = ""
    @Published private(set) var identity: Identity?

    struct Identity: Equatable {
        var name: String?
        var email: String?
    }

    var sending: Bool { pending != nil }

    // Le message en route est peut-être déjà arrivé par le direct, avant la
    // réponse de l'envoi : il ne s'affiche pas deux fois.
    var pendingArrived: Bool {
        guard let p = pending else { return false }
        return messages.contains { m in
            !m.fromTeam && m.createdAt >= p.startedAt.addingTimeInterval(-60)
                && m.body == p.body && m.attachments.count == p.files.count
        }
    }
    var hasConversation: Bool { token != nil && !messages.isEmpty }
    var accent: HexColor { HexColor(site?.color) ?? .hookyDefault }

    private let tokenStore: TokenStoring
    private let defaults: UserDefaults
    private let makeCable: @MainActor (URL, String) -> ConversationCable
    private let log = Logger(subsystem: "com.heyhooky.sdk", category: "Hooky")
    private var cable: ConversationCable?
    private var appActive = true
    private var typingTimer: Task<Void, Never>?
    private var lastReadSent: Int?
    private var lastLinksRefresh = Date.distantPast
    private var fetchedAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var siteTask: Task<Void, Never>?

    // Les liens signés valent une heure : passé 50 minutes, on relit le fil.
    static let linksFreshFor: TimeInterval = 50 * 60
    static let typingShownFor: TimeInterval = 4

    init(siteKey: String, api: HookyAPI, texts: Texts, tokenStore: TokenStoring = KeychainTokenStore(),
         defaults: UserDefaults = .standard,
         makeCable: (@MainActor (URL, String) -> ConversationCable)? = nil,
         observeLifecycle: Bool = true) {
        self.siteKey = siteKey
        self.api = api
        self.texts = texts
        self.tokenStore = tokenStore
        self.defaults = defaults
        let app = api.app
        self.makeCable = makeCable ?? { url, token in ConversationCable(baseURL: url, token: token, app: app) }
        self.token = tokenStore.token(for: siteKey)
        self.draft = defaults.string(forKey: draftKey) ?? ""
        if observeLifecycle { observe() }
    }

    // MARK: - Démarrage

    // L'apparence du site, puis la conversation enregistrée s'il y en a une
    // (avec le temps réel).
    func start() {
        siteTask?.cancel()
        siteTask = Task { [weak self] in
            await self?.loadSite()
            await self?.resume()
        }
    }

    func loadSite() async {
        do {
            site = try await api.site()
        } catch HookyError.http(let status, let code) {
            log.error("Hooky: the site couldn't be loaded (HTTP \(status), \(code ?? "-", privacy: .public)). Check the site key, and that the site accepts apps.")
        } catch {
            // Hors ligne : la bulle garde les couleurs par défaut, on réessaiera à l'ouverture.
        }
    }

    func resume() async {
        guard token != nil else { return }
        await fetchConversation()
    }

    // MARK: - Le fil

    func fetchConversation() async {
        guard let token else { return }
        do {
            let r = try await api.thread(token: token)
            guard token == self.token else { return }
            load(r)
            connect()
            markRead()
        } catch HookyError.http(let status, _) where status == 401 || status == 404 {
            forget()
        } catch {}
    }

    private func load(_ r: ThreadResponse) {
        conversation = r.conversation
        teamReadAt = r.conversation.teamReadAt
        add(r.messages)
        hasMore = r.hasMore == true
        fetchedAt = Date()
    }

    // Un message déjà connu est remplacé : relu, il apporte des liens neufs.
    func add(_ incoming: [Message]) {
        var all = messages
        var index: [Int: Int] = [:]
        for (i, m) in all.enumerated() { index[m.id] = i }
        for m in incoming {
            if let i = index[m.id] { all[i] = m } else { index[m.id] = all.count; all.append(m) }
        }
        all.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        messages = all
        updateUnread()
    }

    func loadOlder() async {
        guard let token, let first = messages.first, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let r = try await api.thread(token: token, before: first.id)
            add(r.messages)
            hasMore = r.hasMore == true
        } catch {
            self.error = errorText(error)
        }
    }

    // Des liens de pièces jointes expirés (une heure) : on relit le fil, page
    // après page jusqu'aux plus anciens messages affichés. Une fois par 20 s
    // au plus, pour qu'une image vraiment cassée ne fasse pas tourner la bulle.
    func refreshLinks() {
        guard let token, let oldest = messages.first?.id, Date().timeIntervalSince(lastLinksRefresh) > 20 else { return }
        lastLinksRefresh = Date()
        Task {
            var before: Int?
            while true {
                guard let r = try? await api.thread(token: token, before: before) else { return }
                add(r.messages)
                if before == nil {
                    teamReadAt = r.conversation.teamReadAt
                    conversation = r.conversation
                    fetchedAt = Date()
                }
                guard r.hasMore == true, let first = r.messages.first, first.id > oldest else { return }
                before = first.id
            }
        }
    }

    func refreshLinksIfStale() {
        let attachments = messages.contains { !$0.attachments.isEmpty }
        if attachments, Date().timeIntervalSince(fetchedAt) > Self.linksFreshFor { refreshLinks() }
    }

    // MARK: - Le temps réel

    private func connect() {
        guard let token, conversation != nil, cable == nil, appActive else { return }
        let c = makeCable(api.baseURL, token)
        c.onEvent = { [weak self] event in self?.receive(event) }
        c.onConfirmed = { [weak self] in
            // Après une coupure, on relit le fil pour ne rien manquer.
            guard let self, !self.messages.isEmpty else { return }
            Task { await self.fetchConversation() }
        }
        c.onRejected = { [weak self] in
            // Le jeton est peut-être mort : le fil le dira (401 → oubli).
            guard let self else { return }
            self.cable = nil
            Task { await self.fetchConversation() }
        }
        cable = c
        c.start()
    }

    private func disconnect() {
        cable?.stop()
        cable = nil
    }

    func receive(_ event: CableEvent) {
        switch event {
        case .message(let m):
            add([m])
            if m.fromTeam {
                teamTypingName = nil
                typingTimer?.cancel()
                markRead()
            }
        case .typing(let sender, let author):
            guard sender == "team" else { return }
            teamTypingName = (author?.isEmpty == false ? author : nil) ?? site?.name ?? ""
            typingTimer?.cancel()
            typingTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.typingShownFor * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.teamTypingName = nil
            }
        case .read(let sender, let readAt):
            guard sender == "team" else { return }
            teamReadAt = readAt
        }
    }

    private func draftChanged(_ old: String) {
        guard draft != old else { return }
        if draft.isEmpty { defaults.removeObject(forKey: draftKey) } else { defaults.set(draft, forKey: draftKey) }
        if error != nil, !sending { error = nil }
        if token != nil, !draft.isEmpty { cable?.sendTyping() }
    }

    // MARK: - Lu, non-lus

    private var draftKey: String { "hooky.draft.\(siteKey)" }
    private var seenKey: String { "hooky.seen.\(siteKey)" }

    // Le dernier message de l'équipe vu par le visiteur (id), gardé d'un
    // lancement à l'autre.
    private var lastSeenTeamID: Int? {
        get { defaults.object(forKey: seenKey) as? Int }
        set { if let newValue { defaults.set(newValue, forKey: seenKey) } else { defaults.removeObject(forKey: seenKey) } }
    }

    // Les messages de l'équipe pas encore vus. Sans repère (l'app vient d'être
    // réinstallée, le jeton retrouvé dans le trousseau), ceux arrivés après le
    // dernier message du visiteur.
    func updateUnread() {
        let count: Int
        if let seen = lastSeenTeamID {
            count = messages.filter { $0.fromTeam && $0.id > seen }.count
        } else {
            let lastVisitor = messages.last { !$0.fromTeam }
            count = messages.filter { $0.fromTeam && (lastVisitor == nil || $0.createdAt > lastVisitor!.createdAt) }.count
        }
        if count != unreadCount { unreadCount = count }
    }

    // Lu : seulement à l'écran, app au premier plan. L'équipe voit « Lu ».
    func markRead() {
        guard isPresented, appActive, let token, let lastTeam = messages.last(where: \.fromTeam) else { return }
        if (lastSeenTeamID ?? 0) < lastTeam.id { lastSeenTeamID = lastTeam.id }
        updateUnread()
        guard lastReadSent != lastTeam.id else { return }
        lastReadSent = lastTeam.id
        Task {
            do { try await api.markRead(token: token) } catch { if lastReadSent == lastTeam.id { lastReadSent = nil } }
        }
    }

    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            if site == nil { Task { await loadSite() } }
            markRead()
            refreshLinksIfStale()
        }
    }

    // MARK: - L'envoi

    func identify(name: String?, email: String?) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = n?.isEmpty == false ? n : nil
        let mail = e?.isEmpty == false ? e : nil
        identity = name == nil && mail == nil ? nil : Identity(name: name, email: mail)
    }

    var canSend: Bool {
        !sending && preparing == 0 && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    // Le texte et les fichiers partent ensemble ; raté, ils reviennent dans la saisie.
    func submit() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard canSend else { return }
        draft = ""
        attachments = []
        let sent = await send(body, files: files)
        if !sent {
            draft = body + (draft.isEmpty ? "" : "\n" + draft)
            attachments = Array((files + attachments).prefix(AttachmentRules.maxFiles))
        }
    }

    @discardableResult
    func send(_ body: String, files: [OutgoingFile]) async -> Bool {
        let first = token == nil
        error = nil
        pending = Pending(body: body, files: files, progress: files.isEmpty ? nil : 0, startedAt: Date(),
                          previews: files.filter(\.isImage).compactMap { UIImage(contentsOfFile: $0.url.path) })
        let progress: @Sendable (Double) -> Void = { [weak self] part in
            Task { @MainActor in
                guard let self, self.pending != nil else { return }
                self.pending?.progress = part
            }
        }
        do {
            if first {
                let name = identity?.name ?? formName.trimmingCharacters(in: .whitespacesAndNewlines)
                let email = identity?.email ?? formEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                let r = try await api.createConversation(body: body, name: name, email: email, locale: texts.language,
                                                         timeZone: TimeZone.current.identifier, files: files, progress: progress)
                guard let newToken = r.conversation.token else { throw HookyError.http(status: 500, code: nil) }
                await ImageCache.shared.seed(files, for: r.messages)
                token = newToken
                tokenStore.setToken(newToken, for: siteKey)
                load(r)
                connect()
            } else {
                guard let token else { throw HookyError.notConfigured }
                let m = try await api.sendMessage(token: token, body: body, files: files, progress: progress)
                await ImageCache.shared.seed(files, for: [m])
                add([m])
                // Un message du visiteur rouvre une conversation close.
                conversation?.closed = false
            }
            FilePreparation.discard(files)
            pending = nil
            return true
        } catch {
            pending = nil
            if !(error is CancellationError) { self.error = errorText(error) }
            return false
        }
    }

    func errorText(_ error: Error) -> String {
        switch (error as? HookyError)?.code {
        case "file_too_large": return texts("lourd_api")
        case "file_type_not_allowed": return texts("refuse_api")
        case "too_many_files": return texts("quatre")
        case "empty_message": return texts("vide")
        case "storage_unavailable": return texts("stockage")
        default: break
        }
        if (error as? HookyError) == .offline { return texts("hors_ligne") }
        return (error as? HookyError)?.status == 429 ? texts("trop") : texts("echec")
    }

    // MARK: - Les pièces jointes

    // Des fichiers en préparation (photo réduite, copie) ; au-delà de 4, ou
    // refusés, un message dit pourquoi.
    func attach(_ jobs: [@Sendable () async throws -> OutgoingFile]) {
        let room = max(0, AttachmentRules.maxFiles - attachments.count - preparing)
        error = jobs.count > room ? texts("quatre") : nil
        for job in jobs.prefix(room) {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                do {
                    let file = try await job()
                    if attachments.count < AttachmentRules.maxFiles {
                        attachments.append(file)
                    } else {
                        FilePreparation.discard([file])
                        error = texts("quatre")
                    }
                } catch let refusal as AttachmentRefusal {
                    error = refusal.text(texts)
                } catch {
                    self.error = texts("illisible")
                }
            }
        }
    }

    func remove(_ file: OutgoingFile) {
        attachments.removeAll { $0.id == file.id }
        FilePreparation.discard([file])
        error = nil
    }

    // MARK: - Oubli, cycle de vie

    // Le jeton ne vaut plus rien (conversation supprimée), ou l'app
    // déconnecte son utilisateur : on repart d'une page blanche.
    func forget(clearIdentity: Bool = false) {
        disconnect()
        tokenStore.setToken(nil, for: siteKey)
        token = nil
        conversation = nil
        messages = []
        hasMore = false
        teamTypingName = nil
        teamReadAt = nil
        lastReadSent = nil
        lastSeenTeamID = nil
        unreadCount = 0
        if clearIdentity {
            identity = nil
            formName = ""
            formEmail = ""
            draft = ""
            FilePreparation.discard(attachments)
            attachments = []
            error = nil
        }
    }

    // En arrière-plan, le temps réel se coupe ; au retour, il se rouvre et
    // le fil est relu (à la confirmation de l'abonnement).
    func appDidEnterBackground() {
        appActive = false
        disconnect()
    }

    func appWillEnterForeground() {
        appActive = true
        guard token != nil else { return }
        if conversation != nil { connect() } else { Task { await fetchConversation() } }
        markRead()
        refreshLinksIfStale()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillEnterForeground() }
        })
    }

    func tearDown() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        siteTask?.cancel()
        disconnect()
    }
}
