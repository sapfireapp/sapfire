import SwiftUI
import AppKit

// MARK: - Settings → Websites

/// Все свои настройки сайтов в одном месте: у каждого сайта — блок с ярлыками того, что у него своё;
/// клик — его настройки прямо здесь (как в шестерёнке адресной строки, но без открытой вкладки),
/// плюс «Open in» — профиль или общий ящик VPN. «Add Website…» — настроить сайт заранее.
struct WebsitesPage: View {
    @State private var settings = SiteSettings.shared
    @State private var query = ""
    @State private var open: String?
    /// Добавленные вручную, пока у них ещё нет ни одной своей настройки
    @State private var added: [String] = []
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let all = Websites.sites().union(added).sorted()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let list = all.filter { q.isEmpty || $0.contains(q) || Websites.summary($0).joined(separator: " ").lowercased().contains(q) }
        VStack(alignment: .leading, spacing: Metrics.inset) {
            HStack(spacing: Metrics.inset) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search websites", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color.primary.opacity(Metrics.blockShade), in: Capsule())
                Button("Add Website…") { add() }.controlSize(.small)
                if !all.isEmpty { Button("Reset All…") { resetAll(all) }.controlSize(.small) }
            }
            Text("Everything you set up for websites. Click a site to change it here, or use the gear in the address bar.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.settingsPad)
                .padding(.vertical, 4)
            if list.isEmpty {
                Text(all.isEmpty ? "No sites with their own settings yet." : "Nothing found")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            ForEach(list, id: \.self) { site in
                // Без анимации высоты: прокрутка окна настроек меняет высоту рывком, и блок дёргался
                SiteBlock(site: site, expanded: open == site, toggle: { open = open == site ? nil : site }, changed: { tick += 1 })
            }
        }
        // Правки из шестерёнки сайта, «Always Open As», стирание элементов — всё в UserDefaults; страница перечитывает
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in tick += 1 }
    }

    private func add() {
        guard let s = promptText("Website address (for example, youtube.com)", initial: ""),
              let site = Websites.site(from: s) else { return }
        if !added.contains(site) { added.append(site) }
        query = ""
        open = site
    }

    private func resetAll(_ sites: [String]) {
        let a = NSAlert()
        a.messageText = "Reset settings of all \(sites.count) sites?"
        a.informativeText = "Zoom, permissions, erased elements, allowed requests, VPN and profile rules — everything set up for websites will be removed."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for s in sites { Websites.reset(s) }
        added = []
        open = nil
        tick += 1
    }
}

/// Блок сайта: шапка (значок, имя, ярлыки) и по клику — его настройки
private struct SiteBlock: View {
    let site: String
    let expanded: Bool
    let toggle: () -> Void
    let changed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsPad / 2) {
            // Одна строка: значок, имя, ярлыки (переносятся, только если не влезли), стрелка
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Favicon(url: URL(string: "https://" + site)).frame(width: 16, height: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(site).font(.system(size: 13, weight: .medium)).fixedSize()
                    WrapChips(items: Websites.summary(site))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.top] + 13 }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.15), value: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { SiteEditor(site: site, changed: changed) }
        }
        .padding(.horizontal, Metrics.settingsPad)
        .padding(.vertical, Metrics.settingsPad * 0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(Metrics.blockShade), in: RoundedRectangle(cornerRadius: Metrics.settingsRadius, style: .circular))
    }
}

/// Настройки одного сайта (без открытой вкладки): правки сразу в сохранённые, открытые страницы сайта — заново
private struct SiteEditor: View {
    let site: String
    let changed: () -> Void
    @State private var settings = SiteSettings.shared
    @State private var tick = 0

    private var url: URL? { URL(string: "https://" + site) }

    var body: some View {
        let _ = tick
        let p = settings.all[site] ?? SitePrefs()
        let look = PageTweaks.shared.sites[site] ?? PageTweaks.Site()      // сохранённое (не правки инкогнито)
        VStack(alignment: .leading, spacing: 8) {
            // Где открывать: профиль пространства, общий ящик VPN или свой профиль
            heading("Open In")
            row("Network and logins") { openInPicker }
            if BrowserModel.profileRules[site] == Profile.vpnID {
                hint("Opens through the VPN, with its own logins shared by all VPN sites. Sign in there once.")
            }

            heading("Page")
            row("Zoom") {
                Picker("", selection: Binding(get: { p.zoom }, set: { v in set { $0.zoom = v } })) {
                    // ⌘+/⌘− сохраняют шаг 10% — такое значение тоже должно быть в списке, иначе меню пустое
                    ForEach(Set(Websites.zooms).union([p.zoom]).sorted(), id: \.self) { z in Text("\(Int((z * 100).rounded()))%").tag(z) }
                }
                .labelsHidden().fixedSize()
            }
            row("Show as") {
                Picker("", selection: Binding(get: { p.userAgent }, set: { v in set(reload: true) { $0.userAgent = v } })) {
                    Text("Automatic").tag("auto")
                    Text("Mobile").tag("mobile")
                }
                .labelsHidden().fixedSize()
            }
            toggle("Always open in Reader", p.reader) { v in set { $0.reader = v } }
            toggle("Always translate", p.translate) { v in set { $0.translate = v } }
            toggle("Dark page", look.dark) { v in tweak { $0.dark = v } }
            toggle("Hide sticky headers", look.unstick) { v in tweak { $0.unstick = v } }
            row("Font") {
                Picker("", selection: Binding(get: { look.font }, set: { v in tweak { $0.font = v } })) {
                    Text("Default").tag("default")
                    Text("Serif").tag("serif")
                    Text("Sans").tag("sans")
                    Text("Mono").tag("mono")
                }
                .labelsHidden().fixedSize()
            }
            if !look.erased.isEmpty {
                row("Erased elements: \(look.erased.count)") {
                    Button("Bring Back") { tweak { $0.erased = [] } }.controlSize(.small)
                }
            }
            toggle("JavaScript", p.javaScript) { v in set(reload: true) { $0.javaScript = v } }
            toggle("Load web fonts", p.webFonts) { v in set(reload: true) { $0.webFonts = v } }
            row("Pop-up windows") {
                Picker("", selection: Binding(get: { p.popups }, set: { v in set { $0.popups = v } })) {
                    Text("Allow").tag("allow")
                    Text("Block").tag("block")
                }
                .labelsHidden().fixedSize()
            }
            row("Auto-play") {
                Picker("", selection: Binding(get: { p.autoplay }, set: { v in set(reload: true) { $0.autoplay = v } })) {
                    Text("Allow").tag("allow")
                    Text("Stop Media with Sound").tag("nosound")
                    Text("Stop All Media").tag("deny")
                }
                .labelsHidden().fixedSize()
            }

            heading("Privacy")
            toggle("Block ads and trackers", p.blocker) { v in set(reload: true) { $0.blocker = v } }
                .disabled(!ContentBlocker.shared.enabled)
            toggle("Fingerprint protection", p.fingerprint) { v in set(reload: true) { $0.fingerprint = v } }
                .help("Where it’s on (Settings → Privacy → Tracking). Off — the site sees this Mac as it is: helps when a site keeps asking whether you’re a robot.")
            let allowed = BlockerPrefs.shared.allows.filter { $0.site == site }
            ForEach(allowed) { a in
                row("Allowed: \(a.host)") {
                    Button("Block Again") { BlockerPrefs.shared.removeAllow(a); refresh(reload: true) }.controlSize(.small)
                }
            }
            row("Cookies") {
                Picker("", selection: Binding(get: { p.cookies }, set: { v in set(reload: true) { $0.cookies = v } })) {
                    Text("Allow").tag(true)
                    Text("Block").tag(false)
                }
                .labelsHidden().fixedSize()
            }

            heading("Permissions")
            row("Camera") { ask(p.camera) { v in set { $0.camera = v } } }
            row("Microphone") { ask(p.microphone) { v in set { $0.microphone = v } } }
            row("Location") { ask(p.location) { v in set { $0.location = v } } }
            row("Screen sharing") {
                Picker("", selection: Binding(get: { p.screenShare }, set: { v in set(reload: true) { $0.screenShare = v } })) {
                    Text("Ask").tag("ask")
                    Text("Deny").tag("deny")
                }
                .labelsHidden().fixedSize()
            }
            row("Other apps") { ask(p.externalApps) { v in set { $0.externalApps = v } } }
            row("Apps on this Mac") {
                Picker("", selection: Binding(get: { LocalBridge.decisions[site].map { $0 ? "allow" : "deny" } ?? "ask" }, set: { v in
                    var d = LocalBridge.decisions
                    d[site] = v == "ask" ? nil : v == "allow"
                    LocalBridge.decisions = d
                    refresh()
                })) {
                    Text("Ask").tag("ask")
                    Text("Allow").tag("allow")
                    Text("Deny").tag("deny")
                }
                .labelsHidden().fixedSize()
            }
            row("Downloads") {
                Picker("", selection: Binding(get: { p.downloads }, set: { v in set { $0.downloads = v } })) {
                    Text("Allow").tag("allow")
                    Text("Deny").tag("deny")
                }
                .labelsHidden().fixedSize()
            }

            Divider().opacity(0).frame(height: 2)
            HStack {
                Toggle("Compatibility Mode", isOn: Binding(get: { p.paused }, set: { v in set(reload: true) { $0.paused = v } }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Show the site as is: your settings for it are switched off (not deleted)")
                Spacer()
                Button("Reset Site…") {
                    let a = NSAlert()
                    a.messageText = "Reset all settings for \(site)?"
                    a.informativeText = "Everything set up for this site will be removed."
                    a.addButton(withTitle: "Reset")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { Websites.reset(site); refresh(reload: true) }
                }
                .controlSize(.small)
            }
        }
        .font(.system(size: 12))
    }

    // MARK: Открыть в

    private var openInPicker: some View {
        let m = BrowserModel.current
        let profiles = m.profiles
        // Профили в списке только когда их больше одного; правило на отсутствующий — как «у пространства»
        let listed = profiles.count > 1 ? Set(profiles.map(\.id)) : []
        return Picker("", selection: Binding(get: {
            guard let r = BrowserModel.profileRules[site], r == Profile.vpnID || listed.contains(r) else { return "space" }
            return r.uuidString
        }, set: { v in
            let want = v == "space" ? nil : UUID(uuidString: v)
            var r = BrowserModel.profileRules
            r[site] = want
            BrowserModel.profileRules = r
            // Открытые страницы сайта — заново, уже по новому правилу (нужными входами и дорогой)
            for t in Websites.openTabs(site) where !t.temporary {
                guard let sp = m.space(of: t), !sp.isIncognito, t.effectiveProfileID != (want ?? sp.profileID) else { continue }
                m.reopenAs(t, profile: want ?? sp.profileID)
            }
            refresh(reload: false)
        })) {
            Text("Space’s profile").tag("space")
            Text("Through VPN").tag(Profile.vpnID.uuidString)
            if profiles.count > 1 {
                Divider()
                ForEach(profiles) { pr in
                    Text(Tunnel.isOn(pr.id) && !pr.name.localizedCaseInsensitiveContains("vpn") ? "\(pr.name) (VPN)" : pr.name).tag(pr.id.uuidString)
                }
            }
        }
        .labelsHidden().fixedSize()
    }

    // MARK: Строки

    private func heading(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).lineLimit(1).truncationMode(.middle); Spacer(minLength: 8); c() }
    }

    private func toggle(_ label: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { on }, set: set)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private func ask(_ value: String, _ set: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(get: { value }, set: set)) {
            Text("Ask").tag("ask")
            Text("Allow").tag("allow")
            Text("Deny").tag("deny")
        }
        .labelsHidden().fixedSize()
    }

    // MARK: Правки

    private func set(reload: Bool = false, _ f: (inout SitePrefs) -> Void) {
        settings.updateSaved(site, f)
        refresh(reload: reload)
    }

    private func tweak(_ f: (inout PageTweaks.Site) -> Void) {
        PageTweaks.shared.updateSaved(site, f)
        refresh(reload: true)
    }

    /// Открытые страницы сайта — под новые настройки
    private func refresh(reload: Bool = false) {
        tick += 1
        changed()
        for t in Websites.openTabs(site) {
            if reload { t.reload() } else { t.webView?.pageZoom = settings.prefs(t.url).zoom }
        }
    }
}

/// Ярлыки в строку с переносом
private struct WrapChips: View {
    let items: [String]
    var body: some View {
        ChipFlow(spacing: 4) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.system(size: 10.5))
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Color.primary.opacity(Metrics.blockShade), in: Capsule())
            }
        }
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(w, maxX), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Сбор настроек сайтов

enum Websites {
    static let zooms: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    /// Все сайты, у которых есть хоть что-то своё
    static func sites() -> Set<String> {
        var s = Set(SiteSettings.shared.all.keys)
        s.formUnion(PageTweaks.shared.sites.keys)
        s.formUnion(BlockerPrefs.shared.allows.map(\.site))
        s.formUnion(LocalBridge.decisions.keys)
        s.formUnion(BrowserModel.profileRules.keys)
        return s
    }

    /// «youtube.com», «https://www.youtube.com/watch…» → «youtube.com»
    static func site(from text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let s = SiteSettings.site(URL(string: t)), s.contains(".") else { return nil }
        return s
    }

    /// Что у сайта своё — короткими ярлыками
    static func summary(_ site: String) -> [String] {
        var out: [String] = []
        if let r = BrowserModel.profileRules[site] {
            if r == Profile.vpnID { out.append("Through VPN") }
            else if let p = BrowserModel.current.profiles.first(where: { $0.id == r }) { out.append("Opens as \(p.name)") }
        }
        let p = SiteSettings.shared.all[site] ?? SitePrefs()
        let d = SitePrefs()
        if p.paused { out.append("Compatibility Mode") }
        if p.zoom != d.zoom { out.append("Zoom \(Int((p.zoom * 100).rounded()))%") }
        if !p.blocker { out.append("Blocker off") }
        let allowed = BlockerPrefs.shared.allows.filter { $0.site == site }.count
        if allowed > 0 { out.append("\(allowed) allowed") }
        if !p.javaScript { out.append("JavaScript off") }
        if p.userAgent != d.userAgent { out.append(p.userAgent == "mobile" ? "Mobile version" : "Desktop version") }
        if p.reader { out.append("Always Reader") }
        if p.translate { out.append("Always translate") }
        if p.popups != d.popups { out.append("Pop-ups blocked") }
        if p.autoplay != d.autoplay { out.append(p.autoplay == "deny" ? "No autoplay" : "Autoplay muted") }
        if !p.cookies { out.append("No cookies") }
        if !p.webFonts { out.append("No web fonts") }
        if p.camera != d.camera { out.append("Camera: \(p.camera.capitalized)") }
        if p.microphone != d.microphone { out.append("Microphone: \(p.microphone.capitalized)") }
        if p.location != d.location { out.append("Location: \(p.location.capitalized)") }
        if p.downloads != d.downloads { out.append("Downloads blocked") }
        if p.externalApps != d.externalApps { out.append("Other apps: \(p.externalApps.capitalized)") }
        if p.screenShare != d.screenShare { out.append("Screen sharing blocked") }
        if !p.fingerprint { out.append("No fingerprint protection") }
        if let v = LocalBridge.decisions[site] { out.append(v ? "Apps on this Mac: Allow" : "Apps on this Mac: Deny") }
        if let t = PageTweaks.shared.sites[site] {
            if !t.erased.isEmpty { out.append("\(t.erased.count) erased") }
            if t.dark { out.append("Dark page") }
            if t.unstick { out.append("No sticky headers") }
            if t.font != "default" { out.append("Font: \(t.font.capitalized)") }
        }
        return out
    }

    /// Убрать у сайта всё своё
    static func reset(_ site: String) {
        SiteSettings.shared.reset(URL(string: "https://" + site))        // и вид страницы (PageTweaks) тоже
        for a in BlockerPrefs.shared.allows where a.site == site { BlockerPrefs.shared.removeAllow(a) }
        var d = LocalBridge.decisions; d[site] = nil; LocalBridge.decisions = d
        var r = BrowserModel.profileRules; r[site] = nil; BrowserModel.profileRules = r
    }

    /// Открытые вкладки сайта во всех окнах
    static func openTabs(_ site: String) -> [Tab] {
        var seen = Set<ObjectIdentifier>()
        return BrowserModel.windows.flatMap { $0.spaces.flatMap(\.tabs) }.filter {
            $0.webView != nil && SiteSettings.site($0.url) == site && seen.insert(ObjectIdentifier($0)).inserted
        }
    }
}
