import AppKit
import SwiftUI

// MARK: - Модули (как аддоны в Blender)

/// Ядро Sapfire лёгкое; необязательное — модули, их включают и выключают в Settings → Modules.
/// Выключенный модуль не грузит свой код в страницы и не показывает своих кнопок.
enum Module: String, CaseIterable, Identifiable {
    case extensions, boosts, peek, miniPlayer, autoReload, summarize, capture, tidyTitles, localApps
    // Впереди (из роадмапа) — видны, но пока не включаются
    case liveFolders, notes, airTraffic, autoPiP
    var id: String { rawValue }

    var planned: Bool {
        switch self {
        case .liveFolders, .notes, .airTraffic, .autoPiP: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .extensions: "Extensions"
        case .boosts: "Look"
        case .peek: "Peek"
        case .miniPlayer: "Mini Player"
        case .autoReload: "Auto Reload"
        case .summarize: "Summarize"
        case .liveFolders: "Live Folders"
        case .capture: "Capture Image"
        case .tidyTitles: "Tidy Tab Titles"
        case .localApps: "Apps on This Mac"
        case .notes: "Notes"
        case .airTraffic: "Air Traffic Control"
        case .autoPiP: "Auto Picture in Picture"
        }
    }

    var icon: String {
        switch self {
        case .extensions: "puzzlepiece.extension"
        case .boosts: "wand.and.stars"
        case .peek: "rectangle.on.rectangle"
        case .miniPlayer: "play.rectangle"
        case .autoReload: "timer"
        case .summarize: "sparkles"
        case .liveFolders: "folder.badge.gearshape"
        case .capture: "camera.viewfinder"
        case .tidyTitles: "textformat.abc"
        case .localApps: "app.connected.to.app.below.fill"
        case .notes: "note.text"
        case .airTraffic: "arrow.triangle.branch"
        case .autoPiP: "pip"
        }
    }

    var color: Color {
        switch self {
        case .extensions: .purple
        case .boosts: .pink
        case .peek: .blue
        case .miniPlayer: .red
        case .autoReload: .orange
        case .summarize: .indigo
        case .capture: .teal
        case .tidyTitles: .green
        case .localApps: .brown
        default: .gray
        }
    }

    var summary: String {
        switch self {
        case .extensions: "Safari, Chrome and Firefox extensions: buttons in the toolbar, the Extensions menu. Needs macOS 15.4."
        case .boosts: "Erase elements, dark page, no sticky headers, own font — per website, from the gear in the address bar."
        case .peek: "A link from a pinned tab to another site opens as a card above the page."
        case .miniPlayer: "Video or music from another tab keeps playing in a small player at the bottom of the sidebar."
        case .autoReload: "Reload a tab by itself every few minutes, keeping zoom and scroll position."
        case .summarize: "A summary of the page or selected text and questions about it — by Gemini, with a free key. Off in incognito."
        case .liveFolders: "Folders that fill themselves: new mail, GitHub issues and the like."
        case .tidyTitles: "Pinned tabs get short, clean names — by Gemini when Summarize has a key, otherwise by trimming site names and counters. Right-click a tab → Rename… or Tidy Title."
        case .capture: "Point at any picture on a page and take it at full size — copy, save or drag it out. ⇧⌘2, the “⋯” menu or right-click."
        case .localApps: "Websites you allow can talk to apps on this Mac over a local connection — for example a 3D site sending a model straight to Blender. Each site asks first."
        case .notes: "Quick notes next to the pages."
        case .airTraffic: "Rules for which links open in which space."
        case .autoPiP: "Video goes picture-in-picture when you switch tabs."
        }
    }

    /// Ключ настройки (у Peek — прежний, чтобы не сбросилось)
    var key: String { self == .peek ? Prefs.peekPinned : "module." + rawValue }

    /// Выключен, пока не включат: нужен немногим (мост к программам на Mac)
    var defaultOn: Bool { self != .localApps }

    var isOn: Bool { !planned && (UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn) }

    static func isOn(_ m: Module) -> Bool { m.isOn }
}

/// Settings → Modules: список модулей с выключателями
struct ModulesPage: View {
    @State private var tick = 0

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 14) {
            Text("The core of Sapfire stays light. Everything else is a module — turn on what you need; a module that’s off doesn’t load anything into pages.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Module.allCases.filter { !$0.planned }) { row($0) }
            Text("COMING LATER")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 8)
            ForEach(Module.allCases.filter(\.planned)) { row($0) }
        }
    }

    private func row(_ m: Module) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: m.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(m.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .circular))
                .opacity(m.planned ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.system(size: 13, weight: .medium))
                Text(m.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .capsAtTop(13)
            Spacer(minLength: 12)
            if m.planned {
                Text("Planned").font(.system(size: 11)).foregroundStyle(.tertiary).frame(height: 30)
            } else {
                Toggle("", isOn: Binding(get: { m.isOn }, set: { on in
                    UserDefaults.standard.set(on, forKey: m.key)
                    tick += 1
                    Modules.changed(m, on)
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .scaleEffect(0.85)
                .frame(height: 30)          // по центру значка в начале строки
            }
        }
        .opacity(m.planned ? 0.7 : 1)
    }
}

enum Modules {
    /// Модуль включили или выключили — что-то применить сразу
    static func changed(_ m: Module, _ on: Bool) {
        switch m {
        case .extensions:
            Ext.moduleChanged(on)
            BrowserModel.current.showToast(on ? "Extensions on — open tabs pick them up after reloading" : "Extensions off")
        case .boosts:
            BrowserModel.current.showToast("Look applies to pages as they load")
        case .localApps:
            BrowserModel.current.showToast(on ? "Apps on This Mac on — pages pick it up as they load" : "Apps on This Mac off")
        default: break
        }
    }
}

extension View {
    /// Верх заглавных букв первой строки — вровень с верхним краем соседа (значка) в HStack(alignment: .top)
    func capsAtTop(_ size: CGFloat, weight: NSFont.Weight = .medium) -> some View {
        let cap = NSFont.systemFont(ofSize: size, weight: weight).capHeight
        return alignmentGuide(.top) { $0[.firstTextBaseline] - cap }
    }
}
