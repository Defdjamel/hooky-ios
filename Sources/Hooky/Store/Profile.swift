// Ce que l'app dit du visiteur (Hooky.identify, Hooky.setAttributes) et que
// le serveur ne sait pas encore : envoyé avec le premier message, puis par
// PATCH /v1/widget/conversation, regroupé (un appel pour plusieurs
// changements dans la seconde). Un champ à nil reste inchangé ; une donnée
// libre à nil est supprimée côté serveur.
import Foundation

struct ProfileChanges: Equatable, Sendable {
    var name: String?
    var email: String?
    var userID: String?
    var attributes: [String: HookyValue?] = [:]

    var isEmpty: Bool { name == nil && email == nil && userID == nil && attributes.isEmpty }

    // Les plus récents (newer) l'emportent, les autres restent.
    func merging(_ newer: ProfileChanges) -> ProfileChanges {
        var out = self
        if let n = newer.name { out.name = n }
        if let e = newer.email { out.email = e }
        if let u = newer.userID { out.userID = u }
        out.attributes.merge(newer.attributes) { _, new in new }
        return out
    }

    // Le corps du PATCH : visitor_device en plus, toujours (une app mise à
    // jour, un système aussi).
    func body(device: String?) -> [String: Any] {
        var b: [String: Any] = [:]
        if let name { b["visitor_name"] = name }
        if let email { b["visitor_email"] = email }
        if let userID { b["visitor_user_id"] = userID }
        if !attributes.isEmpty { b["visitor_attributes"] = Self.json(attributes) }
        if let device { b["visitor_device"] = device }
        return b
    }

    // { "plan": "Pro", "panier": 49.9, "ancienne": null } ; un nombre qui
    // n'en est pas un (NaN, infini) ferait échouer JSONSerialization : écarté.
    static func json(_ attributes: [String: HookyValue?]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in attributes {
            switch value {
            case .none: out[key] = NSNull()
            case .some(.number(let n)) where !n.isFinite: continue
            case .some(let v): out[key] = v.jsonValue
            }
        }
        return out
    }
}

// Une chaîne vide ou faite d'espaces ne dit rien.
func cleaned(_ text: String?) -> String? {
    let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    return t?.isEmpty == false ? t : nil
}
