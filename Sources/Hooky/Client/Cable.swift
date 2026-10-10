// Le temps réel : un client Action Cable minimal pour la conversation du
// visiteur, comme connect() de widget/widget.js.
//
// - wss://…/cable?conversation_token=…&client=…&app=… (sous-protocole
//   actioncable-v1-json), avec les en-têtes X-Hooky-Client et X-Hooky-App ;
// - à l'accueil (welcome), abonnement à ConversationChannel ; à la
//   confirmation, rattrapage (le fil est relu : rien de manqué pendant la
//   coupure) ; un refus veut dire que le jeton ne vaut plus rien ;
// - événements message, typing et read ; « typing » envoyé au plus toutes
//   les 2 s ;
// - reconnexion avec un délai qui double (1 s, 2 s, 4 s… 30 s au plus) ; le
//   serveur envoie un ping toutes les 3 s : sans nouvelles depuis 10 s, la
//   connexion est morte (veille, changement de réseau).
import Foundation

enum CableEvent: Equatable, Sendable {
    case message(Message)
    case typing(sender: String, authorName: String?)
    case read(sender: String, readAt: Date?)
}

// Une trame reçue, déjà comprise.
enum CableFrame: Equatable, Sendable {
    case welcome
    case ping
    case confirmed
    case rejected
    case disconnect(reconnect: Bool)
    case event(CableEvent)
    case ignored

    static func parse(_ text: String, identifier: String) -> CableFrame {
        guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return .ignored }
        switch frame["type"] as? String {
        case "welcome": return .welcome
        case "ping": return .ping
        case "confirm_subscription": return .confirmed
        case "reject_subscription": return .rejected
        case "disconnect": return .disconnect(reconnect: frame["reconnect"] as? Bool ?? true)
        default: break
        }
        guard frame["identifier"] as? String == identifier, let message = frame["message"] as? [String: Any] else { return .ignored }
        switch message["type"] as? String {
        case "message":
            guard let m = JSON.decode(Message.self, from: message["message"]) else { return .ignored }
            return .event(.message(m))
        case "typing":
            return .event(.typing(sender: message["sender"] as? String ?? "", authorName: message["author_name"] as? String))
        case "read":
            return .event(.read(sender: message["sender"] as? String ?? "", readAt: (message["read_at"] as? String).flatMap(JSON.date)))
        default:
            return .ignored
        }
    }
}

// Le délai avant de se reconnecter : 1 s, puis le double à chaque échec,
// 30 s au plus ; remis à 1 s quand le serveur accueille la connexion.
struct Backoff: Equatable, Sendable {
    var initial: TimeInterval = 1
    var maximum: TimeInterval = 30
    private(set) var current: TimeInterval = 1

    init(initial: TimeInterval = 1, maximum: TimeInterval = 30) {
        self.initial = initial
        self.maximum = maximum
        self.current = initial
    }

    mutating func next() -> TimeInterval {
        let delay = current
        current = min(current * 2, maximum)
        return delay
    }

    mutating func reset() {
        current = initial
    }
}

// Le WebSocket lui-même, derrière un protocole : les tests en mettent un faux.
@MainActor
protocol CableTransport: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func open(_ request: URLRequest)
    func send(_ text: String)
    func close()
}

@MainActor
final class WebSocketTransport: CableTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func open(_ request: URLRequest) {
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, t === self.task else { return }
                switch result {
                case .success(.string(let text)):
                    self.onText?(text)
                    self.receive(t)
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) { self.onText?(text) }
                    self.receive(t)
                case .success:
                    self.receive(t)
                case .failure:
                    self.task = nil
                    self.onClose?()
                }
            }
        }
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

@MainActor
final class ConversationCable {
    // Ce que le fil apprend du direct.
    var onEvent: ((CableEvent) -> Void)?
    // Abonné (après une coupure aussi) : le fil se relit.
    var onConfirmed: (() -> Void)?
    // Le serveur refuse le jeton.
    var onRejected: (() -> Void)?
    private(set) var connected = false
    private(set) var subscribed = false

    static let identifier = #"{"channel":"ConversationChannel","id":0}"#
    static let typingInterval: TimeInterval = 2

    private let baseURL: URL
    private let token: String
    private let app: String
    private let makeTransport: @MainActor () -> CableTransport
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let watchdogInterval: TimeInterval?
    private var transport: CableTransport?
    private var backoff = Backoff()
    private var stopped = true
    private var generation = 0
    private var lastSignal = Date()
    private var lastTypingSent = Date.distantPast
    private var watchdog: Task<Void, Never>?

    init(baseURL: URL, token: String, app: String = SDKInfo.app,
         makeTransport: @escaping @MainActor () -> CableTransport = { WebSocketTransport() },
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = ConversationCable.later,
         watchdogInterval: TimeInterval? = 10) {
        self.baseURL = baseURL
        self.token = token
        self.app = app
        self.makeTransport = makeTransport
        self.schedule = schedule
        self.watchdogInterval = watchdogInterval
    }

    static func later(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            action()
        }
    }

    // L'adresse du WebSocket : celle de l'API en ws(s)://, le jeton et la
    // présentation du client en paramètres (un WebSocket de navigateur ne
    // porte pas d'en-têtes ; ici on met les deux).
    static func url(baseURL: URL, token: String, app: String) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.path = "/cable"
        c.queryItems = [
            URLQueryItem(name: "conversation_token", value: token),
            URLQueryItem(name: "client", value: SDKInfo.client),
            URLQueryItem(name: "app", value: app),
        ]
        return c.url!
    }

    var request: URLRequest {
        var r = URLRequest(url: Self.url(baseURL: baseURL, token: token, app: app))
        r.setValue("actioncable-v1-json, actioncable-unsupported", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        r.setValue(SDKInfo.client, forHTTPHeaderField: "X-Hooky-Client")
        r.setValue(app, forHTTPHeaderField: "X-Hooky-App")
        return r
    }

    func start() {
        guard stopped else { return }
        stopped = false
        backoff.reset()
        open()
    }

    // L'app passe en arrière-plan, ou la conversation est oubliée : on coupe
    // sans se reconnecter.
    func stop() {
        stopped = true
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        transport?.onClose = nil
        transport?.close()
        transport = nil
        connected = false
        subscribed = false
    }

    private func open() {
        guard !stopped else { return }
        generation += 1
        let current = generation
        let t = makeTransport()
        transport = t
        t.onText = { [weak self] text in
            guard let self, self.generation == current else { return }
            self.received(text)
        }
        t.onClose = { [weak self] in
            guard let self, self.generation == current else { return }
            self.lost()
        }
        lastSignal = Date()
        t.open(request)
        watch()
    }

    private func received(_ text: String) {
        lastSignal = Date()
        switch CableFrame.parse(text, identifier: Self.identifier) {
        case .welcome:
            connected = true
            backoff.reset()
            write(["command": "subscribe", "identifier": Self.identifier])
        case .confirmed:
            subscribed = true
            onConfirmed?()
        case .rejected:
            stop()
            onRejected?()
        case .disconnect(let reconnect):
            if !reconnect {
                // Connexion refusée (jeton inconnu) : pas la peine d'insister.
                stop()
                onRejected?()
            }
        case .event(let event):
            onEvent?(event)
        case .ping, .ignored:
            break
        }
    }

    private func lost() {
        watchdog?.cancel()
        transport = nil
        connected = false
        subscribed = false
        guard !stopped else { return }
        let delay = backoff.next()
        let current = generation
        schedule(delay) { [weak self] in
            guard let self, !self.stopped, self.generation == current, self.transport == nil else { return }
            self.open()
        }
    }

    private func watch() {
        watchdog?.cancel()
        guard let interval = watchdogInterval else { return }
        let current = generation
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.generation == current else { return }
                if Date().timeIntervalSince(self.lastSignal) > interval {
                    self.transport?.onClose = nil
                    self.transport?.close()
                    self.lost()
                    return
                }
            }
        }
    }

    // Le visiteur écrit : l'équipe le voit, au plus toutes les 2 s.
    func sendTyping(now: Date = Date()) {
        guard subscribed, now.timeIntervalSince(lastTypingSent) >= Self.typingInterval else { return }
        lastTypingSent = now
        write(["command": "message", "identifier": Self.identifier, "data": #"{"action":"typing"}"#])
    }

    private func write(_ object: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return }
        transport?.send(text)
    }
}
