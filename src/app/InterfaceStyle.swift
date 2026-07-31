import Foundation

enum InterfaceStyle: String, Codable, CaseIterable, Sendable {
    case dock = "dock"
    case tray = "tray"
    case both = "both"

    var displayName: String {
        switch self {
        case .dock: return "Dock"
        case .tray: return "Tray"
        case .both: return "Both"
        }
    }
}
