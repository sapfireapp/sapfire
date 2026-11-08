import AppKit
import SwiftUI
import WebKit

// MARK: - Мини-плеер внизу панели

/// Ушёл с вкладки, где играет музыка или видео, — внизу панели карточка: что играет, пауза, звук,
/// «картинка в картинке». Клик по карточке — вернуться на вкладку.
@Observable
final class MiniPlayer {
    static let shared = MiniPlayer()
    /// Поставлена на паузу из мини-плеера — карточка остаётся, хотя звука уже нет
    var pausedID: UUID?
    /// На странице есть видео (можно «картинку в картинке»)
    var hasVideo: [UUID: Bool] = [:]

    /// Что показывать: поставленная здесь на паузу или последняя из играющих, которых сейчас не видно
    func tab(_ model: BrowserModel) -> Tab? {
        let all = model.allTabs.filter { !IncognitoLock.hides($0) }
        if let id = pausedID, let t = all.first(where: { $0.id == id }), t.webView != nil, !model.isVisible(t) { return t }
        return all.filter { $0.audible && !model.isVisible($0) }.max { $0.lastActive < $1.lastActive }
    }

    /// Скрипт — в главной рамке и в рамке, где играет видео (плееры часто во встроенной рамке другого сайта)
    private func run(_ js: String, in t: Tab, onlyVideoFrame: Bool = false) {
        guard let wv = t.webView else { return }
        let frame = MediaFrames.shared.frame(for: wv)
        if !(onlyVideoFrame && frame != nil) { wv.evaluateJavaScript(js) }
        if let f = frame { wv.evaluateJavaScript(js, in: f, in: .page) { _ in } }
    }

    func togglePlay(_ t: Tab) {
        guard let wv = t.webView else { return }
        if t.audible || pausedID != t.id {
            // Пауза: запоминаем, что играло, чтобы потом продолжить именно это
            run("document.querySelectorAll('video,audio').forEach(function(m){ if(!m.paused){ m.dataset.sfMini='1'; m.pause(); } })", in: t)
            wv.pauseAllMediaPlayback {}
            pausedID = t.id
        } else {
            run("""
            (function(){ var ms = document.querySelectorAll('[data-sf-mini]');
              if (!ms.length) { var v = document.querySelector('video,audio'); if (v) ms = [v]; }
              ms.forEach(function(m){ delete m.dataset.sfMini; m.play(); }); })()
            """, in: t, onlyVideoFrame: true)
            pausedID = nil
        }
    }

    /// «Картинка в картинке». Движок пускает видео в отдельное окно только с включённой скрытой настройкой
    /// (WebEngine.enablePictureInPicture) — в WKWebView она по умолчанию выключена, и без неё видео отвечает
    /// «не поддерживается». Страница при этом может быть и не в окне (вкладка не на экране) — работает.
    func pictureInPicture(_ t: Tab) {
        run("""
        (function(){ var vs = Array.from(document.querySelectorAll('video')).sort(function(a,b){ return b.clientWidth*b.clientHeight - a.clientWidth*a.clientHeight; });
          var v = vs[0]; if (!v) return;
          if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) v.webkitSetPresentationMode('picture-in-picture');
          else if (v.requestPictureInPicture) v.requestPictureInPicture().catch(function(){}); })()
        """, in: t, onlyVideoFrame: true)
    }

    /// ✕ — остановить и убрать карточку
    func stop(_ t: Tab) {
        t.webView?.pauseAllMediaPlayback {}
        if pausedID == t.id { pausedID = nil }
    }

    /// Для какого адреса вкладки проверяли (на странице-приложении видео может появиться позже — проверяем заново)
    private var probed: [UUID: String] = [:]
    func probeVideo(_ t: Tab) {
        let key = t.url?.absoluteString ?? ""
        guard probed[t.id] != key, let wv = t.webView else { return }
        probed[t.id] = key
        wv.evaluateJavaScript("!!Array.from(document.querySelectorAll('video')).find(function(v){ return v.clientWidth > 160 })") { r, _ in
            self.hasVideo[t.id] = (r as? Bool) ?? false
        }
    }
}

/// Рамка, где играет видео: страница сообщает о нём из любой рамки (и из встроенного плеера другого сайта),
/// чтобы мини-плеер и «картинка в картинке» работали с ним, а не искали видео только в главной рамке
final class MediaFrames: NSObject, WKScriptMessageHandler {
    static let shared = MediaFrames()
    private var frames: [ObjectIdentifier: WKFrameInfo] = [:]

    static let script = WKUserScript(source: """
    document.addEventListener('playing', function(e){
      var v = e.target; if (!v || v.tagName !== 'VIDEO') return;
      try { window.webkit.messageHandlers.sfMedia.postMessage({ w: v.clientWidth, h: v.clientHeight }); } catch (err) {}
    }, true);
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    func install(in c: WKUserContentController) {
        c.addUserScript(Self.script)
        c.add(self, name: "sfMedia")
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView else { return }
        frames[ObjectIdentifier(wv)] = message.frameInfo.isMainFrame ? nil : message.frameInfo
        let w = (message.body as? [String: Any])?["w"] as? Double ?? 0
        if w > 160, let t = BrowserModel.windows.lazy.compactMap({ $0.tab(for: wv) }).first { MiniPlayer.shared.hasVideo[t.id] = true }
    }

    /// Встроенная рамка с видео (nil — видео в главной рамке или не играло)
    func frame(for wv: WKWebView) -> WKFrameInfo? { frames[ObjectIdentifier(wv)] }
    func forget(_ wv: WKWebView) { frames[ObjectIdentifier(wv)] = nil }
}

/// Карточка в широкой панели
struct MiniPlayerCard: View {
    /// Радиус угла панели, в которой стоит плеер
    var outerRadius: CGFloat = Metrics.cardRadius
    @Environment(BrowserModel.self) private var model
    @State private var mp = MiniPlayer.shared
    @State private var hover = false

    /// Видео впервые ушло в мини-плеер — подсказка (один раз)
    var body: some View {
        card.onChange(of: mp.tab(model)?.id, initial: true) { _, id in
            if let id, mp.hasVideo[id] == true { Tips.show(.miniPlayer, model) }
        }
    }

    @ViewBuilder private var card: some View {
        if let t = mp.tab(model) {
            let paused = mp.pausedID == t.id && !t.audible
            let video = mp.hasVideo[t.id] ?? false
            HStack(spacing: 8) {
                // Видео — последний кадр страницы, иначе значок сайта
                Group {
                    if video, let img = t.preview {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: 52, height: 30).clipShape(RoundedRectangle(cornerRadius: 6, style: .circular))
                    } else {
                        Favicon(url: t.url).frame(width: 18, height: 18).frame(width: 30, height: 30)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .circular))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !paused && !t.muted { Equalizer().offset(x: 3, y: 3) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(t.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    MiniButton(icon: paused ? "play.fill" : "pause.fill", help: paused ? "Play" : "Pause") { mp.togglePlay(t) }
                    if hover {
                        MiniButton(icon: t.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: t.muted ? "Unmute" : "Mute") { t.muted.toggle() }
                        if video { MiniButton(icon: "pip.enter", help: "Picture in Picture") { mp.pictureInPicture(t) } }
                        MiniButton(icon: "xmark", help: "Stop") { mp.stop(t) }
                    }
                }
            }
            .padding(.leading, 6).padding(.trailing, 4)
            .frame(height: 42)
            // Скругление концентрично углу панели: её радиус минус отступ до края (6)
            .background(sidebarShade(Metrics.blockShade * 1.4), in: RoundedRectangle(cornerRadius: max(8, outerRadius - 6), style: .circular))
            // По ширине блоков вкладок: их подложка выходит за строки на 4 с каждой стороны
            .padding(.horizontal, -4)
            .contentShape(Rectangle())
            .onTapGesture { model.select(t) }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .help("Playing in “\(t.displayTitle)” — click to go back")
            .onAppear { mp.probeVideo(t) }
            .onChange(of: t.id) { mp.probeVideo(t) }
            .onChange(of: t.url) { mp.probeVideo(t) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// В узкой колонке — значок сайта; клик — пауза / продолжить, правый клик — меню
struct MiniPlayerCell: View {
    @Environment(BrowserModel.self) private var model
    @State private var mp = MiniPlayer.shared
    @State private var hover = false

    var body: some View {
        if let t = mp.tab(model) {
            let paused = mp.pausedID == t.id && !t.audible
            ZStack {
                Circle().fill(sidebarShade(Metrics.blockShade * 1.4))
                if hover {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 11, weight: .semibold))
                } else {
                    Favicon(url: t.url).frame(width: 16, height: 16)
                }
            }
            .frame(width: CompactSidebar.cell, height: CompactSidebar.cell)
            .overlay(alignment: .bottomTrailing) { if !paused && !t.muted { Equalizer().offset(x: 2, y: 2) } }
            .contentShape(Circle())
            .onTapGesture { mp.togglePlay(t) }
            .onHover { hover = $0 }
            .contextMenu {
                Button("Go to Tab") { model.select(t) }
                Button(t.muted ? "Unmute" : "Mute") { t.muted.toggle() }
                Button("Stop") { mp.stop(t) }
            }
            .help(t.displayTitle)
        }
    }
}

private struct MiniButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hover ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Три прыгающие полоски — «играет»
private struct Equalizer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().frame(width: 2, height: 3 + 5 * abs(sin(t * (5 + Double(i) * 1.7) + Double(i))))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 12, height: 10, alignment: .bottom)
            .padding(2)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3, style: .circular))
        }
    }
}
