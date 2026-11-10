#if DEBUG
import AppKit
import os
import SwiftUI
import VettiraCore

/// A snapshot run (`--snapshot <dir>`, Debug builds only): once the snapshot is due
/// (`LaunchOptions.Snapshot.isDue`), draws the menu-bar item, the popover, the dashboard and
/// Settings to PNG files in the directory, in light and dark, then quits. They're the real views
/// on the app's own state, drawn into bitmaps in windows that are never put on screen, so nothing
/// shows on the user's screen and no Screen Recording or Accessibility permission is needed.
@MainActor
final class SnapshotRenderer {
    private let state: AppState
    private let snapshot: LaunchOptions.Snapshot
    private let log = Logger(subsystem: "com.andiamosoftware.vettira", category: "snapshot")

    init(state: AppState, snapshot: LaunchOptions.Snapshot) {
        self.state = state
        self.snapshot = snapshot
    }

    /// Waits until the snapshot is due, renders it and quits: with status 0 when every picture was
    /// written, 1 when one wasn't.
    func start() {
        let started = Date()
        say("Snapshot: waiting \(snapshot.after.map { "\(Int($0)) s" } ?? "for every symbol's stronger warning")")
        Task {
            while !snapshot.isDue(state.snapshot, elapsed: Date().timeIntervalSince(started)) {
                try? await Task.sleep(for: .seconds(1))
            }
            let written = await render()
            exit(written ? 0 : 1)
        }
    }

    private func render() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
        } catch {
            say("Snapshot: couldn't make \(snapshot.directory.path): \(error.localizedDescription)")
            return false
        }
        var written = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearance) else { continue }
            for (picture, view, size) in pictures() {
                let file = snapshot.directory.appending(path: "\(picture)-\(name).png")
                do {
                    try await draw(view, size: size, appearance: appearance).write(to: file)
                    say("Snapshot: wrote \(file.path)")
                } catch {
                    say("Snapshot: couldn't write \(file.path): \(error.localizedDescription)")
                    written = false
                }
            }
        }
        return written
    }

    /// Each picture's name, view and size in points: the popover at the width it shows at and the
    /// height its content takes, the windows at the size they first open at, the menu bar's item
    /// at its own.
    private func pictures() -> [(String, NSView, NSSize?)] {
        let popover = NSHostingView(rootView: MenuBarPopover(state: state, openDashboard: {}, openSettings: {}))
        let dashboard = NSHostingView(rootView: DashboardView(state: state, openSettings: {}))
        let settings = NSHostingView(rootView: SettingsView(state: state))
        let menuBar = menuBar()
        return [
            ("1-menu-bar", menuBar, menuBar.frame.size),
            ("2-popover", popover, nil),
            ("3-dashboard", dashboard, nil),
            ("4-settings", settings, SettingsView.firstSize),
        ]
    }

    /// The menu-bar item as it shows each symbol in its cycle, top to bottom in the cycle's
    /// order, each in a strip the menu bar's height, drawn as `MenuBarController` draws it.
    private func menuBar() -> NSView {
        let symbols = MenuBarCycle.symbols(state.settings)
        let statuses = symbols.isEmpty ? [state.menuBar] : symbols.map { state.menuBar(showing: $0) }
        let items = statuses.map { status in
            let item = NSButton(title: "", target: nil, action: nil)
            item.isBordered = false
            item.image = MenuBarController.image(status)
            item.attributedTitle = MenuBarController.title(status)
            item.sizeToFit()
            return item
        }
        let height = max(NSStatusBar.system.thickness, items.map(\.frame.height).max() ?? 0)
        let width = (items.map(\.frame.width).max() ?? 0) + 16
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height * CGFloat(items.count)))
        for (index, item) in items.enumerated() {
            let row = CGFloat(items.count - 1 - index)
            item.frame.origin = NSPoint(x: 8, y: row * height + (height - item.frame.height) / 2)
            strip.addSubview(item)
        }
        return strip
    }

    /// The view drawn at twice its size in points, as on a Retina screen, on the window
    /// background, in an offscreen window with `appearance`.
    private func draw(_ view: NSView, size: NSSize?, appearance: NSAppearance) async throws -> Data {
        let fitting = size ?? view.fittingSize
        // Whole points, so the bitmap is whole pixels.
        let size = NSSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        guard size.width > 0, size.height > 0 else { throw SnapshotError.empty(size) }
        let backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
        view.frame = backdrop.bounds
        view.autoresizingMask = [.width, .height]
        backdrop.addSubview(view)
        // Never ordered in, so it's never on screen; it gives the views an appearance and a
        // window to lay out in.
        let window = NSWindow(
            contentRect: backdrop.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = backdrop
        backdrop.layoutSubtreeIfNeeded()
        // SwiftUI lays out and fills tables on the next turns of the run loop.
        try await Task.sleep(for: .milliseconds(300))
        backdrop.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SnapshotError.noBitmap(size) }
        bitmap.size = size
        appearance.performAsCurrentDrawingAppearance {
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        }
        window.contentView = nil
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.noPNG }
        return png
    }

    /// To the log, and to standard output for the command that launched the run.
    private func say(_ line: String) {
        log.notice("\(line, privacy: .public)")
        print(line)
        fflush(stdout)
    }

    private enum SnapshotError: LocalizedError {
        case empty(NSSize), noBitmap(NSSize), noPNG
        var errorDescription: String? {
            switch self {
            case .empty(let size): "nothing to draw: it's \(size.width) by \(size.height) points"
            case .noBitmap(let size): "couldn't make a bitmap \(size.width) by \(size.height) points"
            case .noPNG: "couldn't make a PNG"
            }
        }
    }
}

/// The window background the views sit on, in the drawing appearance.
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
#endif
