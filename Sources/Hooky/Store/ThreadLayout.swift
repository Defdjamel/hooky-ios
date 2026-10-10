// Le fil tel qu'il s'affiche, comme threadNodes() de widget.js : le jour
// au-dessus d'une série, le nom de l'auteur (équipe) en tête de série,
// l'heure sous le dernier message d'une série, et « Lu » sous le dernier
// message du visiteur quand l'équipe l'a lu. Une série : même expéditeur,
// même auteur, moins de 5 minutes d'écart, le même jour.
import Foundation

enum ThreadItem: Equatable, Identifiable {
    case day(Date)
    case author(String, messageID: Int)
    case message(Message, first: Bool, last: Bool)
    case time(Date, fromTeam: Bool, read: Bool, messageID: Int)

    var id: String {
        switch self {
        case .day(let d): "d\(Int(d.timeIntervalSince1970))"
        case .author(_, let id): "a\(id)"
        case .message(let m, _, _): "m\(m.id)"
        case .time(_, _, _, let id): "h\(id)"
        }
    }
}

enum ThreadLayout {
    static let seriesGap: TimeInterval = 5 * 60

    static func sameSeries(_ a: Message?, _ b: Message?, calendar: Calendar = .current) -> Bool {
        guard let a, let b else { return false }
        return a.sender == b.sender && a.authorName == b.authorName
            && b.createdAt.timeIntervalSince(a.createdAt) < seriesGap
            && calendar.isDate(a.createdAt, inSameDayAs: b.createdAt)
    }

    static func items(_ messages: [Message], teamReadAt: Date?, calendar: Calendar = .current) -> [ThreadItem] {
        var items: [ThreadItem] = []
        let lastVisitor = messages.last { !$0.fromTeam }
        // « Lu » seulement si le dernier message du fil est celui du visiteur.
        let read = lastVisitor != nil && lastVisitor?.id == messages.last?.id
            && teamReadAt.map { $0 >= lastVisitor!.createdAt } == true

        for (i, m) in messages.enumerated() {
            let before = i > 0 ? messages[i - 1] : nil
            let after = i + 1 < messages.count ? messages[i + 1] : nil
            let newDay = before.map { !calendar.isDate($0.createdAt, inSameDayAs: m.createdAt) } ?? true
            let first = newDay || !sameSeries(before, m, calendar: calendar)
            let last = !sameSeries(m, after, calendar: calendar)

            if newDay { items.append(.day(calendar.startOfDay(for: m.createdAt))) }
            if m.fromTeam, first, let author = m.authorName, !author.isEmpty {
                items.append(.author(author, messageID: m.id))
            }
            items.append(.message(m, first: first, last: last))
            if last {
                items.append(.time(m.createdAt, fromTeam: m.fromTeam, read: read && m.id == lastVisitor?.id, messageID: m.id))
            }
        }
        return items
    }
}
