import AppKit
import Combine

final class EditorState: ObservableObject {
    @Published var tool: Tool = .arrow
    @Published var color: NSColor = Palette.colors[0]
    @Published var width: CGFloat = 4
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    ]
}

enum Settings {
    static var saveDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "saveDirectory") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "saveDirectory") }
    }

    static func screenshotFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).png"
    }
}
