// Les stats : Hooky.track("signup") ou Hooky.track("order", value: 49,
// properties: ["plan": "pro"]). Comme Hooky.track de la bulle web.
import Foundation

/// A property value attached to a tracked event: a string, a number or a boolean.
///
/// Literals work directly: `["plan": "pro", "seats": 3, "trial": true]`.
public enum HookyValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    // Ce que JSONSerialization écrit (un entier reste un entier).
    var jsonValue: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .bool(let b): b
        }
    }
}

struct TrackedEvent: Sendable, Equatable {
    var name: String
    var value: Double?
    var properties: [String: HookyValue]
}
