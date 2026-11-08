import AppKit
import SwiftUI
import WebKit

// MARK: - Peek: ссылка из закреплённой вкладки — карточкой поверх страницы (как в Arc)

/// Закреплённый сайт — «приложение» (почта, задачи, чат): ссылка из него на другой сайт открывается
/// не вкладкой, а карточкой поверх. Посмотрел — закрыл (Esc, клик мимо); нужно — «Open as Tab» или в сплит.
extension BrowserModel {
    static var peekEnabled: Bool { UserDefaults.standard.object(forKey: Prefs.peekPinned) as? Bool ?? true }

    /// Открывать ли ссылку из этой вкладки в Peek: вкладка закреплённая, ссылка ведёт на другой сайт
    func shouldPeek(from t: Tab, to url: URL) -> Bool {
        guard Self.peekEnabled, t.isPinned || isFavorite(t), !currentSpace.isIncognito,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return Self.baseDomain(url.host) != Self.baseDomain(t.url?.host)
    }

    /// Сайт без поддоменов: mail.google.com → google.com, news.bbc.co.uk → bbc.co.uk.
    /// На общих хостингах (user.github.io) поддомен — отдельный владелец, поэтому там сайт — три части
    static func baseDomain(_ host: String?) -> String? {
        guard let h = host?.lowercased() else { return nil }
        let parts = h.split(separator: ".")
        guard parts.count > 2 else { return h }
        let tail2 = parts.suffix(2).joined(separator: ".")
        if sharedHosts.contains(tail2) { return parts.suffix(3).joined(separator: ".") }
        if parts.count > 3, sharedHosts.contains(parts.suffix(3).joined(separator: ".")) { return parts.suffix(4).joined(separator: ".") }
        let second = String(parts[parts.count - 2])
        let short = parts.last!.count == 2 && ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or", "go", "nic", "ltd", "plc", "me", "in"].contains(second)
        return parts.suffix(short ? 3 : 2).joined(separator: ".")
    }

    /// Хостинги, где каждый поддомен — чужой сайт (пароли и Peek их не смешивают)
    private static let sharedHosts: Set<String> = [
        "github.io", "gitlab.io", "bitbucket.io", "vercel.app", "netlify.app", "herokuapp.com", "blogspot.com", "pages.dev",
        "workers.dev", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "s3.amazonaws.com",
        "wordpress.com", "tumblr.com", "wixsite.com", "squarespace.com", "glitch.me", "repl.co", "replit.app", "surge.sh", "now.sh",
        "fly.dev", "onrender.com", "railway.app", "ngrok.io", "ngrok-free.app", "trycloudflare.com", "hf.space", "notion.site",
        "substack.com", "neocities.org", "carrd.co", "webflow.io", "myshopify.com", "bigcartel.com", "duckdns.org", "no-ip.org",
        "dyndns.org", "ddns.net", "github.dev", "codesandbox.io", "stackblitz.com", "lovable.app", "deno.dev", "val.run",
        "appspot.com", "run.app", "cloudfunctions.net", "googleusercontent.com", "sharepoint.com", "weebly.com",
        "mystrikingly.com", "tilda.ws", "beget.tech", "nethouse.ru", "ucoz.ru", "narod.ru", "livejournal.com", "medium.com",
    ]

    /// Открыть Peek. `configuration` — когда страница сама открывает окно (target=_blank): движок ждёт
    /// страницу, созданную с его настройками.
    @discardableResult
    func openPeek(_ url: URL?, configuration: WKWebViewConfiguration? = nil) -> Tab {
        if let old = peek { dismissPeek(old) }
        let t = Tab(url: url)
        t.browser = self
        if let configuration {
            t.ensureWebView(configuration: configuration)
        } else {
            let wv = t.ensureWebView(configuration: Self.makeConfiguration(store: currentSpace.dataStore))
            if let url { wv.load(URLRequest(url: url)) }
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { peek = t }
        return t
    }

    /// Закрыть карточку — страница выгружается
    func closePeek() {
        guard let t = peek else { return }
        withAnimation(.easeOut(duration: 0.16)) { peek = nil }
        dismissPeek(t)
        focusWebView()
    }

    private func dismissPeek(_ t: Tab) {
        // Выгружаем, когда карточка уже скрылась (иначе на миг видна пустая карточка)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if self.peek !== t { t.sleep() } }
    }

    /// Карточка становится обычной временной вкладкой — страница не перезагружается
    func peekToTab() {
        guard let t = peek else { return }
        checkpoint("Open Peek as Tab")
        withAnimation(.easeOut(duration: 0.16)) { peek = nil }
        currentSpace.tabs.insert(t, at: 0)
        select(t)
    }

    /// Карточка — в сплит рядом с текущей страницей
    func peekToSplit() {
        guard let t = peek else { return }
        checkpoint("Open Peek in Split")
        withAnimation(.easeOut(duration: 0.16)) { peek = nil }
        currentSpace.tabs.insert(t, at: 0)
        if currentSpace.selectedTab == nil { select(t) } else { openInSplit(t) }
    }
}

/// Затемнение и карточка над страницей
struct PeekOverlay: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        if let t = model.peek {
            GeometryReader { g in
                let o = g.frame(in: .global).origin
                let a = model.splitDrop.area.width > 0
                    ? model.splitDrop.area.offsetBy(dx: -o.x, dy: -o.y)
                    : CGRect(origin: .zero, size: g.size)
                ZStack {
                    // Клик мимо карточки — закрыть
                    Color.black.opacity(0.22)
                        .contentShape(Rectangle())
                        .onTapGesture { model.closePeek() }
                    PeekCard(tab: t)
                        .frame(width: max(360, min(a.width - 72, 1100)), height: max(300, a.height - 56))
                        .position(x: a.midX, y: a.midY + 4)
                }
            }
            .transition(.opacity.combined(with: .offset(y: 14)))
        }
    }
}

private struct PeekCard: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Favicon(url: tab.url).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                PeekButton(icon: "chevron.left", help: "Back", enabled: tab.canGoBack) { PageSwipe.shared.step(tab.webView, back: true) }
                PeekButton(icon: "rectangle.split.2x1", help: "Open in Split") { model.peekToSplit() }
                PeekButton(icon: "arrow.up.left.and.arrow.down.right", help: "Open as Tab") { model.peekToTab() }
                PeekButton(icon: "xmark", help: "Close — Esc") { model.closePeek() }
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 40)
            WebViewHost(tab: tab)
                .overlay(alignment: .top) { LoadingBar(tab: tab, always: true) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .circular).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .circular).fill(Color.black.opacity(0.35)).blur(radius: 30).offset(y: 14)
                .allowsHitTesting(false)
        }
    }
}

private struct PeekButton: View {
    let icon: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(hover && enabled ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}
