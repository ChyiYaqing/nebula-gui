import AppKit
import SwiftUI

enum Palette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.80, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.48, blue: 0.38, alpha: 1)
    })
    // Explicit dynamic steps: recent SDKs may resolve both native backgrounds to white.
    private static func neutral(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
    static let canvas = neutral(1, 0.09)
    static let surface = neutral(0.94, 0.15)
    static let sidebar = neutral(0.96, 0.12)
    static let onAccent = neutral(1, 0.08)
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        // Without a content shape only drawn pixels are clickable: an unselected tab
        // or sidebar row (clear background) reacted only on its icon and text.
        configuration.label.contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Standard workspace button drawn by SwiftUI. On macOS 13 the system bordered
/// style is an NSButton whose CoreUI size measurement dominated tab switches on a
/// real Intel iMac (~38% of main-thread time), so workspace buttons avoid it.
/// Dialogs keep native buttons for default-button highlighting.
struct NebulaButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let shape = RoundedRectangle(cornerRadius: Palette.small)
        configuration.label
            .font(.system(size: 13, weight: prominent ? .medium : .regular))
            .padding(.horizontal, 12).frame(minHeight: 28)
            .foregroundStyle(prominent ? Palette.onAccent : destructive ? Color.red : Color.primary)
            .background(prominent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)), in: shape)
            .overlay { shape.stroke(prominent ? Color.clear : destructive ? Color.red.opacity(0.35) : Color.primary.opacity(0.14), lineWidth: 1) }
            .brightness(prominent && configuration.isPressed ? -0.06 : 0)
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct NetworkActionButton: View {
    let title: String
    let symbol: String
    let disconnecting: Bool
    /// The menu bar panel uses a full-width button (#65); the window header keeps its compact size.
    var expands = false
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(role: disconnecting ? .destructive : nil, action: action) {
            Label(title, systemImage: disconnecting ? "stop.circle" : symbol)
                .frame(minWidth: 122, maxWidth: expands ? .infinity : nil, minHeight: 40)
        }
        .buttonStyle(ConnectionButtonStyle(destructive: disconnecting))
        .focused($focused)
        .overlay { RoundedRectangle(cornerRadius: Palette.small + 3).stroke(focused ? Palette.accent : .clear, lineWidth: 2).padding(-3).allowsHitTesting(false) }
    }
}

private struct ConnectionButtonStyle: ButtonStyle {
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 12)
            .foregroundStyle(destructive ? Color.red : Palette.onAccent)
            .background(destructive ? Color.red.opacity(0.06) : Palette.accent, in: RoundedRectangle(cornerRadius: Palette.small))
            .overlay { RoundedRectangle(cornerRadius: Palette.small).stroke(destructive ? Color.red.opacity(0.35) : .clear, lineWidth: 1) }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Feedback stays beside the copied address, never in a blocking alert.
struct CopyAddressButton: View {
    let address: String
    let label: String
    let copy: () -> Void
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            copy()
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 40, height: 40)
                .foregroundStyle(copied ? Palette.accent : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()) // Not .borderless: that is an NSButton, one per node row.
        .help(copied ? "已复制" : label)
        .accessibilityLabel(copied ? "已复制 \(address)" : label)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: copied)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
            catch { /* A disappearing row must not update another row's feedback. */ }
        }
        .onChange(of: address) { _ in copied = false }
    }
}

struct SectionTitle: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
    }
}

extension View {
    func nebulaSurface() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.medium))
    }
}

private enum EventTimeCache {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let plain = ISO8601DateFormatter()
    static let style = Date.FormatStyle(date: .abbreviated, time: .standard)
    static let results: NSCache<NSString, NSString> = { let cache = NSCache<NSString, NSString>(); cache.countLimit = 1000; return cache }()
}

/// Log and event rows re-render on every poll. Rebuilding two formatters per call
/// cost ~180 ms per 400 rows on a 2019 Intel iMac, so formatters are shared and
/// each timestamp is formatted once.
func eventTime(_ raw: String) -> String {
    if let hit = EventTimeCache.results.object(forKey: raw as NSString) { return hit as String }
    let text = (EventTimeCache.fractional.date(from: raw) ?? EventTimeCache.plain.date(from: raw))
        .map { $0.formatted(EventTimeCache.style) } ?? raw
    EventTimeCache.results.setObject(text as NSString, forKey: raw as NSString)
    return text
}
