import AppKit
import SwiftUI

@MainActor
final class DrawerSettingsController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(workspace: DrawerWorkspace) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Finder Drawer Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: DrawerSettingsView(workspace: workspace))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("Use init(workspace:)") }

    func windowWillClose(_ notification: Notification) {
        // AppKit still reports isVisible during windowWillClose.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}

private struct DrawerSettingsView: View {
    @Bindable var workspace: DrawerWorkspace

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "slider.horizontal.3") }
            browser.tabItem { Label("Browsing", systemImage: "folder") }
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            access.tabItem { Label("Files & Access", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 600, height: 540)
        .onChange(of: workspace.preferences.showHiddenFiles) { workspace.applyPreferences() }
        .onChange(of: workspace.preferences.sortOrder) { workspace.applyPreferences() }
    }

    private var general: some View {
        @Bindable var preferences = workspace.preferences
        return Form {
            Section("Global Shortcut") {
                LabeledContent("Show or hide drawer") {
                    ShortcutRecorder(preferences: preferences).frame(width: 190, height: 28)
                    Button("Reset") { preferences.shortcut = .controlOptionSpace }
                }
                Text("Click the shortcut, then press a key with Control, Option, or Command. Escape cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = preferences.shortcutError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                Text("Works from any app. If the drawer is behind another window, the shortcut brings it forward.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Drawer") {
                Toggle("Enable drawer", isOn: $preferences.isDrawerEnabled)
                Text(preferences.isDrawerEnabled
                     ? "Opens at the top of the display under your pointer."
                     : "Hides and reopens at its last position and size.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Hide when switching to another app", isOn: $preferences.hideOnDeactivate)
                Toggle("Animate opening and closing", isOn: $preferences.animateDrawer)
                    .disabled(!preferences.isDrawerEnabled)
                LabeledContent("Width on next opening") {
                    Slider(value: $preferences.drawerWidth, in: 0.4...1, step: 0.05)
                        .frame(width: 160).accessibilityLabel("Drawer width")
                    Text(preferences.drawerWidth, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 40)
                }
                .disabled(!preferences.isDrawerEnabled)
                LabeledContent("Height on next opening") {
                    Slider(value: $preferences.drawerHeight, in: 0.35...0.9, step: 0.05)
                        .frame(width: 160).accessibilityLabel("Drawer height")
                    Text(preferences.drawerHeight, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 40)
                }
                .disabled(!preferences.isDrawerEnabled)
                Text("Reduce Motion in macOS also disables animation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var browser: some View {
        @Bindable var preferences = workspace.preferences
        return Form {
            Section("File List") {
                Toggle("Show hidden files", isOn: $preferences.showHiddenFiles)
                Toggle("Show file sizes", isOn: $preferences.showItemSizes)
                Picker("Sort by", selection: $preferences.sortOrder) {
                    ForEach(BrowserSort.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Window Controls") {
                Label("Resize, minimize, tile, or enter full screen", systemImage: "macwindow")
                Text("Use the standard traffic lights or the Window menu while the drawer is focused. Closing the drawer keeps your tabs ready for the next opening.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var appearance: some View {
        @Bindable var preferences = workspace.preferences
        return Form {
            Section("Terminal Themes") {
                Picker("Light mode", selection: $preferences.lightTerminalTheme) {
                    ForEach(TerminalTheme.choices(dark: false)) { Text($0.label).tag($0) }
                }.pickerStyle(.menu)
                Picker("Dark mode", selection: $preferences.darkTerminalTheme) {
                    ForEach(TerminalTheme.choices(dark: true)) { Text($0.label).tag($0) }
                }.pickerStyle(.menu)
                Text("Follows your window’s appearance. Changes apply to all terminal tabs immediately and are saved for next time.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("System uses native macOS colors. Nord Snow is a light adaptation of Nord.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use System Colors") {
                    preferences.lightTerminalTheme = .system
                    preferences.darkTerminalTheme = .system
                }
            }
            Section("Terminal Rendering") {
                Toggle("Use GPU rendering (Metal)", isOn: $preferences.terminalUsesGPU)
                Text("Draws terminal text on the GPU, which uses less CPU for heavy output. Falls back to standard drawing automatically if Metal is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var access: some View {
        @Bindable var folders = workspace.folders
        return Form {
            Section("File Access") {
                Toggle("Manage files outside indexed folders", isOn: $folders.allowsSystemWideAccess)
                Text("Browse and manage any location your macOS account can access. Turning this off limits browser file changes to your indexed folders. Terminal shells use your account’s normal permissions.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Protected folders") {
                    Button("Open Full Disk Access…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
                Text("To access protected data, add Finder Drawer with the + button in System Settings and turn it on, then quit and reopen the app. macOS requires you to grant this permission; the app cannot enable it automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            Section("Search Index") {
                Text("Only these folders are indexed. Search includes file names, excludes hidden and ignored files, and does not read file contents.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(folders.folders, id: \.self) { root in
                    HStack {
                        Label(root.path, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { workspace.removeFolder(root) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove \(root.lastPathComponent) from search")
                            .accessibilityLabel("Remove \(root.lastPathComponent) from search")
                    }
                }
                HStack {
                    Button("Add Folders…", action: workspace.chooseFolders)
                    Spacer()
                    Button("Refresh Index", action: workspace.index.rebuildIndex)
                }
            }
        }.formStyle(.grouped)
    }
}
