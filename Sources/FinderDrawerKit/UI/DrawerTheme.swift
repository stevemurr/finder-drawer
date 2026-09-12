import AppKit
import SwiftUI

enum DrawerTheme {
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let shellFill = Color.accentColor.opacity(0.12)
    static let shell = Color.accentColor
    static let text = Color.primary
    static let muted = Color.secondary
}
