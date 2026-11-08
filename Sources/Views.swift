import AppKit
import SwiftUI
import WebKit

// MARK: - Прикрытие жёлоба прокрутки

/// Пока страница перестраивается, движок мигает светлым жёлобом прокрутки справа — прикрываем его цветом сайта.
struct ScrollerShield: View {
    @Environment(BrowserModel.self) private var model
    let active: Bool
    var body: some View {
        if active, NSScroller.preferredScrollerStyle == .legacy {
            Rectangle()
                .fill(Color(nsColor: model.activeTab?.pageColor ?? .textBackgroundColor))
                .frame(width: 16)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Фон окна

/// Обычный режим — полупрозрачный фон с оттенком пространства; Floating — цвет сайта под карточкой.
struct WindowBackground: View {
    @Environment(BrowserModel.self) private var model
    let floating: Bool

    var body: some View {
        // Фон окна всегда в цвет сайта: светлому системному фону негде «проглянуть» кромкой по краю страницы
        if model.currentSpace.paneTabs.count > 1 {
            // Сплит: панели лежат на общей подложке (к ней — «мостик» от строки сплита)
            Color(nsColor: Metrics.splitCard)
        } else if model.activeTab != nil || floating {
            // Незнакомый сайт ещё не сообщил цвет — оставляем прежний, без вспышки.
            // Вкладки нет (пустое пространство) — цвет пустой страницы, а не сайта из прошлого пространства
            let c = model.activeTab == nil ? NSColor.windowBackgroundColor
                : model.activeTab?.pageColor ?? model.lastPageColor ?? .textBackgroundColor
            // Фон под панелью — в цвет страницы и меняется вместе с ней: сама страница переключается сразу,
            // поэтому при смене вкладки фон тоже сразу (иначе рассинхрон); сайт сменил цвет сам — плавно
            PageEdgeFill(tab: model.activeTab, fallback: c)
                .animation(.easeOut(duration: 0.2), value: c)
                .transaction(value: model.activeTab?.id) { $0.animation = nil; $0.disablesAnimations = true }
                .onChange(of: model.activeTab?.pageColor) { _, n in if let n { model.lastPageColor = n } }
        } else {
            ZStack {
                VisualEffect()
                model.swipe.tint(model).opacity(0.28)
            }
        }
    }
}

/// Цвет панели вкладок (для фона под панелями сплита)
struct PanelFill: ShapeStyle {
    let model: BrowserModel
    func resolve(in environment: EnvironmentValues) -> Color {
        let sp = model.currentSpace
        return sp.isIncognito ? Color(white: 0.11) : model.swipe.panel(model)
    }
}

// MARK: - Форма страницы

/// Прямоугольник страницы, начинающийся с отступа слева; левые углы скруглены как у окна.
struct PageShape: Shape {
    var inset: CGFloat
    var radius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inset, radius) }
        set { inset = newValue.first; radius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var r = rect
        r.origin.x += inset
        r.size.width = max(0, r.width - inset)
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .circular).path(in: r)
    }
}

/// «Мостик» активной вкладки: выходит из левого края страницы в панель.
/// Левые углы скруглены, у края страницы — плавные вогнутые переходы сверху и снизу.
struct PageTongue: Shape {
    var row: CGRect          // строка вкладки (в координатах окна)
    var edge: CGFloat        // левый край страницы
    /// Мостик двигается плавно (вместе со строкой вкладки)
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(row.minX, row.minY), .init(row.width, row.height)) }
        set { row = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
    var radius: CGFloat = Metrics.rowRadius        // полукруглый торец, как у строк вкладок
    var fillet: CGFloat = 16                       // плавный переход мостика в страницу
    func path(in _: CGRect) -> Path {
        let x0 = row.minX, x1 = edge, y0 = row.minY, y1 = row.maxY
        let f = min(fillet, max(0, x1 - x0 - radius)), rad = radius
        var p = Path()
        guard x1 - x0 > rad * 2 else { return p }
        p.move(to: CGPoint(x: x0 + rad, y: y0))
        p.addLine(to: CGPoint(x: x1 - f, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 - f), radius: f)
        p.addLine(to: CGPoint(x: x1 + 0.5, y: y0 - f))
        p.addLine(to: CGPoint(x: x1 + 0.5, y: y1 + f))
        p.addLine(to: CGPoint(x: x1, y: y1 + f))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - f, y: y1), radius: f)
        p.addLine(to: CGPoint(x: x0 + rad, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - rad), radius: rad)
        p.addLine(to: CGPoint(x: x0, y: y0 + rad))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + rad, y: y0), radius: rad)
        p.closeSubpath()
        return p
    }
}

/// Тёмный ли цвет (для подписи на «мостике»).
func isDark(_ c: NSColor?) -> Bool {
    guard let c = c?.usingColorSpace(.sRGB) else { return false }
    return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
}

/// Плавное перестроение списка (раскрыть папку, веточки): все его движения — одной пружиной,
/// и вырез активной вкладки, узнав о новом месте строки чуть позже, едет с той же пружиной.
enum ListMotion {
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static var until = Date.distantPast
    static func animate(_ body: () -> Void) {
        until = Date().addingTimeInterval(0.45)
        withAnimation(spring, body)
    }
}

/// Где сейчас строка активной вкладки (для «мостика» к странице).
@Observable
final class ActiveRow {
    /// Своё у каждого окна; `shared` — у окна, в котором сейчас работают
    static var shared: ActiveRow { BrowserModel.current.activeRow }
    @ObservationIgnored weak var model: BrowserModel?
    init(model: BrowserModel) { self.model = model }
    var tabID: UUID?
    var frame: CGRect = .zero
    /// Кто сообщил: ячейка узкой колонки или строка широкой панели. При переключении ширины
    /// обе живут одновременно — берём только ту, что соответствует текущему виду панели.
    private(set) var compact = false
    /// Какая именно строка сообщила (одна вкладка может быть нарисована дважды на миг: свернули папку —
    /// строка пересоздаётся; уходящая не должна стереть то, что уже сообщила новая)
    @ObservationIgnored private var owner: UUID?
    /// В каком пространстве была активная вкладка в прошлый раз
    @ObservationIgnored private var spaceID: UUID?
    /// Рост языка при смене пространства: куда растём (пока не начали) и до какого момента идёт рост
    @ObservationIgnored private var growTarget: CGRect?
    /// Вкладка, чей язык ждёт, чтобы вырасти (строка пока выглядит обычной)
    private(set) var growID: UUID?
    @ObservationIgnored private var growUntil = Date.distantPast
    /// Пространство только что сменили: первая строка нового — через рост от края страницы
    /// (по строкам этого не понять, если в прошлом пространстве строк не было вовсе)
    @ObservationIgnored private var switching = false

    /// Сменили пространство: язык прячем сразу, новый вырастет от края страницы
    func spaceChanged() {
        switching = true
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { tabID = nil }
    }
    func set(_ id: UUID, _ f: CGRect, compact c: Bool, owner o: UUID) {
        guard c == Metrics.compact else { return }
        owner = o
        let sid = model?.currentSpaceID ?? UUID()
        defer { spaceID = sid }
        guard tabID != id || frame != f || compact != c else { return }
        if growID == id {
            growTarget = f          // ещё не начали расти — просто уточняем, куда
        } else if switching || (tabID != id && spaceID != nil && spaceID != sid) {
            switching = false
            // Сменили пространство: язык новой вкладки вырастает из края страницы (справа налево),
            // а не переезжает через всю панель от строки прошлого пространства.
            // 1) на миг прячем (иначе форма выреза плавно поедет вместе с анимацией смены пространства);
            // 2) ставим у края страницы без анимации; 3) растим к строке
            growID = id; growTarget = f
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { tabID = nil; compact = c }
            // Ждём, пока новое пространство доедет (его строки в пути ещё уточняют своё место), и тогда растим
            growLater(id)
        } else if tabID == id, compact == c, Date() < growUntil {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { frame = f }
        } else if tabID == id, compact == c, Date() < ListMotion.until {
            // Строки списка сейчас плавно едут (раскрыли папку, веточки) — вырез едет вместе с ними той же пружиной
            withAnimation(ListMotion.spring) { frame = f }
        } else {
            // Строка сообщила новое место (в том числе промежуточное, пока панель едет) — язык там сразу,
            // без своей анимации: он привязан к строке, а едет она
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { tabID = id; frame = f; compact = c }
        }
    }
    /// Через миг (пока строки доезжают) поставить язык у края страницы без анимации и вырастить к строке
    private func growLater(_ id: UUID, after delay: Double = 0.28) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.growID == id, let g = self.growTarget else { return }
            self.growID = nil; self.growTarget = nil
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { self.tabID = id; self.frame = CGRect(x: g.maxX, y: g.minY, width: 0, height: g.height) }
            self.growUntil = Date().addingTimeInterval(0.5)
            DispatchQueue.main.async {
                guard self.tabID == id else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { self.frame = g }
            }
        }
    }

    func clear(_ id: UUID, compact c: Bool, owner o: UUID) {
        if growID == id && owner == o { growID = nil; growTarget = nil }
        if tabID == id && compact == c && owner == o { tabID = nil }
    }
}

// MARK: - Метрики

/// Единые отступы и скругления: блоки внутри окна стоят на равном отступе
/// от краёв, а их скругление концентрично углу окна (радиус окна − отступ).
enum Metrics {
    /// Угол окна — свой (WindowCorner): на macOS 27 системный угол 16 при любой панели инструментов,
    /// и цепочка капсула → карточка → окно не сходилась (как в Mus3)
    static let windowRadius: CGFloat = 26
    static let inset: CGFloat = 6
    /// Затемнение блоков на панели (подложка папки; строка адреса — чуть плотнее)
    static let blockShade: Double = 0.06
    /// Блоки окна настроек: поле внутри и скругление (капсулы ~22 pt внутри концентричны углу)
    static let settingsPad: CGFloat = 14
    static let settingsRadius: CGFloat = 18      // 25 → 21 → 18: дважды по просьбе на 15% меньше
    /// Тень плавающей панели: размытие, сдвиг вниз, плотность (у стеклянной — чуть плотнее, под ней нет заливки)
    static let shadowRadius: CGFloat = 5.95
    static let shadowY: CGFloat = 1.275
    static let shadowOpacity: Double = 0.161
    static let glassShadowOpacity: Double = 0.184
    /// Подложка под панелями сплита (как страница: с ней соединён «мостик» строки сплита)
    static let splitCard: NSColor = .windowBackgroundColor
    static var cardRadius: CGFloat { windowRadius - inset }
    /// Ширина панели — её можно тянуть за правый край (хранится в модели)
    static var sidebarWidth: CGFloat { BrowserModel.shared.sidebarWidth }
    static let defaultSidebarWidth: CGFloat = 262
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...420
    /// Узкий режим: колонка значков шириной в фавикон
    static let compactWidth: CGFloat = 56
    /// Сколько pt у левой кромки внутри окна вызывают выезд панели
    static let peekEdge: CGFloat = 21
    /// Строки вкладок, папок, поля ввода — с полукруглыми торцами (высота строки 32)
    static let rowRadius: CGFloat = 16
    /// Поле панели: от края панели (карточки) до строк; подсветка строки и подложка папки выходят на 4 — до края 6
    static let sidebarPad: CGFloat = 10
    /// Ширина содержимого панели между полями (у карточки; у прилегающей панели на 2·inset шире). Шире этого
    /// ничего в панели быть не должно: SwiftUI центрирует вылезшее, и весь список съезжает влево
    /// (вырез активной вкладки упирался в край карточки при панели 220 и четырёх сотах)
    static var sidebarContentWidth: CGFloat { sidebarWidth - 2 * inset - 2 * sidebarPad }
    static var compact: Bool { sidebarWidth < 100 }
}

/// Скругление подсветки строк на этом уровне: внутри вложенной папки — на 4 меньше за каждый уровень,
/// чтобы дуги строки, подложки папки и подложки родителя имели общий центр
private struct RowCornerKey: EnvironmentKey { static let defaultValue: CGFloat = Metrics.rowRadius }
extension EnvironmentValues {
    var rowCorner: CGFloat {
        get { self[RowCornerKey.self] }
        set { self[RowCornerKey.self] = newValue }
    }
}

// MARK: - Окно

struct BrowserWindow: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    /// Вырез под активную вкладку в узкой закреплённой колонке (в координатах окна)
    /// Стиль закреплённой панели: attached (лежит под страницей) или floating (карточка над страницей)
    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    private var floating: Bool { model.sidebarVisible && sidebarStyle == "floating" }

    /// Вырез под активную вкладку в карточке Floating (в координатах панели)
    private var floatingNotch: CGRect? {
        guard floating, let t = model.activeTab, t.pageColor != nil,
              model.activeRow.tabID == t.id else { return nil }
        let f = model.activeRow.frame
        let list = model.drag.listZone
        guard f.minY >= list.minY - 1, f.maxY <= list.maxY + 1 else { return nil }
        if Metrics.compact {
            // Круг выреза — как подсветка ячейки (32): до края колонки остаётся Metrics.inset (6), дуга
            // концентрична капсуле колонки (22 − 6 = 16). Круг больше (38) оставлял у края стенку в 3 pt
            let h = f.height
            return CGRect(x: f.midX - h / 2, y: f.midY - h / 2, width: f.maxX - (f.midX - h / 2), height: h)
        }
        // Полукруглый край чуть левее строки — фавикону просторнее; в папке — вровень со строкой
        // (дуга выреза концентрична углам подложки папки и не вылезает за неё)
        let lead: CGFloat = t.folderID != nil ? 0 : 4      // вне папок — как подсветка при наведении
        return CGRect(x: f.minX - lead, y: f.minY, width: f.width + lead, height: f.height)
    }

    private var compactNotch: CGRect? {
        // Вкладка внутри папки — тоже вырезом (подложка папки под вырезом вырезана, см. FolderBlock)
        guard !floating, model.sidebarVisible, Metrics.compact, let t = model.activeTab, t.pageColor != nil,
              model.activeRow.tabID == t.id else { return nil }
        let f = model.activeRow.frame
        let list = model.drag.listZone
        guard f.minY >= list.minY - 1, f.maxY <= list.maxY + 1 else { return nil }
        // Вырез ровно по ячейке (соседние значки не задевает), полукруглый край — точно по центру фавикона
        let h = f.height
        return CGRect(x: f.midX - h / 2, y: f.midY - h / 2, width: f.maxX - (f.midX - h / 2), height: h)
    }
    /// Ширина, под которую сейчас свёрстана страница (меняется скачком — один раз за переключение)
    @State private var layoutInset: CGFloat = -1
    /// Видимый левый край страницы (анимируется)
    @State private var maskInset: CGFloat = -1
    /// На время переключения панели прикрываем жёлоб полосы прокрутки справа (движок мигает им светлым)
    @State private var coverScroller = false
    @State private var coverWork: DispatchWorkItem?
    @State private var pinToken = 0
    /// Снимок страницы в старой раскладке: прикрывает её перестройку в конце закрепления,
    /// пока движок не нарисует новую (иначе на кадр видна старая картинка, сдвинутая вправо)
    @State private var snapshot: NSImage?
    @State private var snapshotOrigin: CGPoint = .zero
    /// Закреплена ли панель — с точки зрения раскладки страницы (nil — как в модели)
    @State private var pagePinned: Bool?
    /// Последний вырез под активную вкладку в карточке Floating / узкой колонке. Пока выреза нет (панель
    /// спрятана), форме отдаём его же: иначе её анимируемая рамка падает в ноль, и при появлении вырез
    /// «прилетает» из левого верхнего угла карточки
    @State private var lastFloatingNotch: CGRect?
    @State private var lastCompactNotch: CGRect?

    /// Вкладка, чей «мостик» сейчас рисуем: панель закреплена (или ещё едет), её строка — активная и в списке
    private func tongueTab(row: ActiveRow, pinned: Bool) -> Tab? {
        guard pinned, !Metrics.compact, !floating else { return nil }
        guard let t = model.activeTab, let id = row.tabID, id == t.id else { return nil }
        let zone = model.drag.listZone.insetBy(dx: 0, dy: -1)
        let f = row.frame
        guard zone.contains(CGPoint(x: f.midX, y: f.minY)), zone.contains(CGPoint(x: f.midX, y: f.maxY)) else { return nil }
        return t
    }

    /// Прикрыть жёлоб прокрутки на время перестройки страницы
    private func shieldScroller() {
        coverWork?.cancel()
        coverScroller = true
        let w = DispatchWorkItem { coverScroller = false }
        coverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    /// Смена раскладки страницы без «грязного» кадра: кладём снимок нынешней картинки на её же место
    /// (левее снимка — заливка цветом сайта), меняем раскладку под ним и убираем снимок,
    /// когда движок нарисовал новую. Иначе кадр-другой видна старая картинка, сдвинутая на ширину панели.
    private func swapLayout(token: Int, valid: @escaping () -> Bool,
                            jump: @escaping (() -> Void) -> Void, apply: @escaping () -> Void) {
        guard model.currentSpace.splitTabs.isEmpty, let wv = model.activeTab?.webView, let win = wv.window,
              let content = win.contentView else {
            jump(apply)
            return
        }
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        let r = wv.convert(wv.bounds, to: nil)
        wv.takeSnapshot(with: cfg) { img, _ in
            guard token == pinToken, valid() else { return }
            jump {
                if let img {
                    snapshot = img
                    snapshotOrigin = CGPoint(x: r.minX, y: content.bounds.height - r.maxY)
                }
                apply()
            }
            // Движок дорисовал новую раскладку (снимок «после обновления экрана» готов) — убираем прикрытие
            let after = WKSnapshotConfiguration()
            after.afterScreenUpdates = true
            after.snapshotWidth = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                wv.takeSnapshot(with: after) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { if token == pinToken { jump { snapshot = nil } } }
                }
            }
            // Запасной выход, если движок не ответил
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if token == pinToken { jump { snapshot = nil } } }
        }
    }

    var body: some View {
        let space = model.currentSpace
        ZStack {
            // Страница: при закреплённой панели плавно уступает ей место и сама
            // становится «окном» — левый край скруглён как у окна, панель выглядывает из-под него
            // Страница перестраивается под новую ширину только один раз: при закреплении —
            // в конце анимации, при откреплении — в начале; движется лишь её видимый край.
            let pinned = model.sidebarVisible
            // Узкая закреплённая колонка лежит поверх страницы со скруглёнными правыми углами —
            // углы загибаются «в обратную сторону», страница под ними прямая
            let compactPinned = pinned && Metrics.compact && !floating
            // Floating: страница прямая, панель — карточка над ней, фон окна в цвет сайта
            let r: CGFloat = pinned && !compactPinned && !floating ? Metrics.windowRadius : 0
            // Сайт рисуется от края панели; у узкой колонки фон цвета страницы заходит под её скруглённые углы
            // Раскладка страницы меняется только из анимации переключения (pagePinned), а не в тот же кадр,
            // когда панель переключилась: иначе страница на кадр перестраивается и дёргается
            let pp = pagePinned ?? pinned
            let settled: CGFloat = pp ? Metrics.sidebarWidth : 0
            let settledMask: CGFloat = pp ? Metrics.sidebarWidth - (pp && Metrics.compact && !floating ? Metrics.sidebarWidth / 2 : 0) : 0
            let mask = maskInset < 0 ? settledMask : maskInset
            PageColumn()
                .padding(.leading, layoutInset < 0 ? settled : layoutInset)
                .overlay(alignment: .topLeading) {
                    // Вырез узкой колонки: закрашиваем цветом страницы (поверх её левой полосы под колонкой)
                    if compactPinned, let n = compactNotch, let c = model.activeTab?.pageColor {
                        // координаты окна: сдвигаем на отступ страницы
                        let lead: CGFloat = layoutInset < 0 ? settled : layoutInset
                        let notchEdge: CGFloat = Metrics.sidebarWidth + 1 - lead
                        PageTongue(row: n.offsetBy(dx: -lead, dy: 0), edge: notchEdge,
                                   radius: n.height / 2, fillet: 6)
                            .fill(Color(nsColor: c))
                            .allowsHitTesting(false)
                    }
                    if let img = snapshot {
                        ZStack(alignment: .topLeading) {
                            // Левее снимка страница ещё не нарисована — там просто цвет сайта
                            Color(nsColor: model.activeTab?.pageColor ?? .textBackgroundColor)
                                .frame(width: max(0, snapshotOrigin.x))
                                .frame(maxHeight: .infinity)
                            Image(nsImage: img).resizable()
                                .frame(width: img.size.width, height: img.size.height)
                                .offset(x: snapshotOrigin.x, y: snapshotOrigin.y)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .trailing) { ScrollerShield(active: coverScroller) }
                .pageClip(PageShape(inset: mask, radius: r))
                .background {
                    // Страница и «мостик» активной вкладки — одно целое, с общей тенью
                    let row = model.activeRow
                    // В сплите панели — карточки на общей подложке; «мостик» ведёт к ней от строки сплита
                    let splitMode = space.paneTabs.count > 1
                    // Панель уезжает — мостик уезжает с ней (ещё виден, пока она в пути)
                    let tongueTab: Tab? = tongueTab(row: row, pinned: pinned)
                    // Левый край мостика — там же, где у подсветки при наведении (4 левее строки).
                    // Пока панель едет — на постоянном расстоянии от края страницы (он анимируется той же пружиной)
                    ZStack(alignment: .topLeading) {
                        // Вырез узкой колонки левее страницы — тоже цветом страницы
                        if compactPinned, let n = compactNotch, let c = model.activeTab?.pageColor {
                            let notchEdge: CGFloat = Metrics.sidebarWidth + 1
                            let notchR: CGFloat = n.height / 2
                            PageTongue(row: n, edge: notchEdge, radius: notchR, fillet: 6)
                                .fill(Color(nsColor: c))
                        }
                        let shapes = ZStack {
                            PageShape(inset: mask, radius: r)
                            if tongueTab != nil {
                                // Левый край мостика — там же, где у подсветки при наведении (4 левее строки)
                                PageTongue(row: CGRect(x: row.frame.minX - 4, y: row.frame.minY,
                                                       width: row.frame.width + 4, height: row.frame.height), edge: mask)
                            }
                        }
                        // Подложка цвета самого сайта: пока движок дорисовывает страницу, не вспыхивает светлый фон.
                        // «Мостик» — продолжение края страницы (её левый столбик пикселей, растянутый вширь)
                        Group {
                            if splitMode { shapes.foregroundStyle(Color(nsColor: Metrics.splitCard)) }
                            else { PageEdgeFill(tab: model.activeTab, fallback: model.activeTab?.pageColor ?? .textBackgroundColor).mask { shapes } }
                        }
                        .compositingGroup()
                        .shadow(color: .black.opacity(pinned && !compactPinned && !floating ? 0.18 : 0), radius: 8, x: -1)
                        if splitMode, let t = tongueTab {
                            // Подпись сплита на «мостике» — те же части, что у строки под ним
                            SplitBridgeLabel(tabs: space.paneTabs, activeID: t.id, dark: isDark(Metrics.splitCard),
                                             indent: space.splitLead(of: t)?.folderID != nil ? 10 : 0)
                                .frame(width: max(0, min(row.frame.width, mask - row.frame.minX)), height: row.frame.height, alignment: .leading)
                                .clipped()
                                .offset(x: row.frame.minX, y: row.frame.minY)
                        } else if let t = tongueTab {
                            // Подпись вкладки поверх «мостика» (сама строка панели — под ним)
                            HStack(spacing: 8) {
                                Favicon(url: t.url).frame(width: 16, height: 16)
                                Text(t.displayTitle).font(.system(size: 13)).lineLimit(1)
                                    // Подпись — по цвету края страницы на высоте строки
                                    .foregroundStyle(isDark(t.edgeStrip?.color(atY: row.frame.midY) ?? t.pageColor) ? Color.white : Color.black.opacity(0.85))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(width: max(0, min(row.frame.width, mask - row.frame.minX)), height: row.frame.height)
                            .offset(x: row.frame.minX, y: row.frame.minY)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .onChange(of: model.currentSpaceID) { model.activeRow.spaceChanged() }
                .onChange(of: floatingNotch) { _, n in if let n { lastFloatingNotch = n } }
                .onChange(of: compactNotch) { _, n in if let n { lastCompactNotch = n } }
            // Зона по периметру окна, за которую его можно перетаскивать
            // (если курсор задержался у края — зона расширяется)
            ZStack {
                VStack(spacing: 0) {
                    DragEdge(axis: .horizontal)
                    Spacer(minLength: 0)
                    DragEdge(axis: .horizontal)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    DragEdge(axis: .vertical)
                }
            }
            // Невидимая полоска у левого края: наведи — панель выедет (и за неё тоже можно тащить)
            WindowDragArea()
                .frame(width: Metrics.peekEdge)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 && !model.sidebarVisible { model.peekEntered() } }
                .allowsHitTesting(!model.sidebarVisible)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Панель — отдельный непрозрачный блок, который выезжает из-за левой кромки
            // Выехавшая по наведению — карточка с отступами поверх страницы;
            // закреплённая — лежит под страницей вровень с краями окна.
            let shown = model.sidebarVisible || model.sidebarPeek
            let card = !pinned || floating          // панель-карточка: выезжающая или закреплённая Floating
            let inset: CGFloat = card ? Metrics.inset : 0
            // Узкая карточка — капсула: верх и низ полукругом на всю ширину
            let radius: CGFloat = !card ? 0 : (Metrics.compact ? (Metrics.sidebarWidth - inset * 2) / 2 : Metrics.cardRadius)
            Sidebar()
                .frame(width: Metrics.sidebarWidth - inset * 2)
                // Выезжающая панель на лету чуть тянется вправо: шире становится только сама карточка
                // (фон, обводка, тень) — содержимое стоит на месте, углы остаются круглыми
                .keyframeAnimator(initialValue: CGFloat(0), trigger: model.sidebarPeek) { content, stretch in
                    content.frame(width: Metrics.sidebarWidth - inset * 2
                                  + (pinned && !compactPinned && !floating ? Metrics.windowRadius : 0)
                                  + (pinned ? 0 : stretch), alignment: .leading)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(model.sidebarPeek ? 4 : 0, duration: 0.09)
                        CubicKeyframe(0, duration: 0.2)
                    }
                }
                .background {
                    let fill = ZStack {
                        if space.isIncognito {
                            // Инкогнито — тёмная панель с лёгким фиолетовым оттенком
                            Color(white: 0.11)
                            Color(hue: 0.75, saturation: 0.5, brightness: 0.5).opacity(0.12)
                        } else {
                            // Стекло: под панелью — размытый рабочий стол (как у меню), цвет и градиент — полупрозрачно поверх
                            // Стекло — только у выехавшей поверх страницы панели: под ней размыта сама страница.
                            // Закреплённая панель всегда сплошная
                            let glass = pinned ? 0 : space.glass
                            if glass > 0 { MenuBackdrop(material: .menu, blending: .withinWindow) }
                            model.swipe.panel(model)
                                // Другое пространство — цвет панели перетекает, а не переключается кадром
                                .animation(.easeInOut(duration: 0.4), value: model.currentSpaceID)
                                .opacity(1 - glass * 0.85)
                            // Мягкий градиент пространства — поверх цвета панели, при смене пространства растворяется
                            if let g = space.glow {
                                SpaceGlowView(glow: g)
                                    .id(space.id)
                                    .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                                    .opacity(1 - (pinned ? 0 : space.glass) * 0.6)
                            }
                        }
                    }
                    // Ветки меняются при закреплении/откреплении — без плавной смены (.identity):
                    // иначе, пока панель уезжает, обе версии фона полупрозрачны и панель выглядит серой
                    if compactPinned {
                        // Узкая закреплённая колонка: фон с вырезом под активную вкладку, тень обходит вырез
                        fill.clipShape(CompactColumnShape(radius: Metrics.sidebarWidth / 2, notch: compactNotch ?? lastCompactNotch, on: compactNotch != nil))
                            .transition(.identity)
                    } else {
                        // Floating: карточка с вырезом под активную вкладку — через вырез виден фон цвета сайта
                        fill.clipShape(CompactColumnShape(radius: radius, notch: floatingNotch ?? lastFloatingNotch, on: floatingNotch != nil))
                            .transition(.identity)
                    }
                }
                .environment(\.colorScheme, space.isIncognito || space.darkPanel ? .dark : (space.colorless ? colorScheme : .light))
                .clipShape(compactPinned
                           ? AnyShape(Rectangle())
                           : AnyShape(RoundedRectangle(cornerRadius: radius, style: .circular)))
                .overlay {
                    // Тонкая обводка карточки (у Floating — по контуру выреза)
                    if card { CompactColumnShape(radius: radius, notch: floatingNotch ?? lastFloatingNotch, on: floatingNotch != nil)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
                }
                .overlay(alignment: .topLeading) {
                    // Первый кружок — в центре скругления угла окна
                    // В узкой колонке светофора нет
                    if !Metrics.compact {
                        TrafficLights()
                            .padding(.leading, Metrics.windowRadius - inset - TrafficLights.size / 2)
                            .padding(.top, Metrics.windowRadius - inset - TrafficLights.size / 2)
                    }
                }
                // Карточка чуть отбита от фона лёгкой тенью: под ней — та же форма цвета панели с тенью
                // (у самой карточки тень обрезалась бы её скруглением)
                .background {
                    if card {
                        Group {
                        let shape = CompactColumnShape(radius: radius, notch: floatingNotch ?? lastFloatingNotch, on: floatingNotch != nil)
                        if !pinned && space.glass > 0 && !space.isIncognito {
                            // Стеклянная панель: тень только снаружи, внутри ничего — иначе под стеклом была бы сплошная заливка
                            shape.fill(Color.black.opacity(Metrics.glassShadowOpacity)).blur(radius: Metrics.shadowRadius).offset(y: Metrics.shadowY)
                                .mask {
                                    ZStack {
                                        Rectangle().padding(-40)
                                        shape.blendMode(.destinationOut)
                                    }
                                    .compositingGroup()
                                }
                                .allowsHitTesting(false)
                        } else {
                            shape
                                .fill(space.isIncognito ? Color(white: 0.11) : model.swipe.panel(model))
                                .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
                        }
                        }
                    }
                }
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // Панель уезжает ровно на свою ширину — столько же, сколько проходит край страницы:
                // край страницы и панель движутся вместе, без пустой полосы между ними
                .offset(x: shown ? 0 : -Metrics.sidebarWidth)
                .allowsHitTesting(shown)
                .zIndex(compactPinned || floating ? 1 : pinned ? -1 : 0)
            // Ручка у правого края панели — растянуть/сузить
            if model.sidebarVisible || model.sidebarPeek {
                SidebarResizeHandle(edge: Metrics.sidebarWidth - (model.sidebarVisible && !floating ? 0 : Metrics.inset)).zIndex(2)
            }
            // Всё, что всплывает поверх, — выше панели (узкая колонка лежит поверх страницы)
            WindowOverlays().zIndex(2)
        }
        .background { WindowBackground(floating: floating).ignoresSafeArea() }
        .background(WindowAccessor(model: model))
        .ignoresSafeArea()
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.sidebarVisible)
        // Выезд быстрее, чем уезд, с одним маленьким отскоком
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: model.topBarShown)
        .animation(model.sidebarPeek ? Animation(PeekBounce()) : .spring(response: 0.3, dampingFraction: 0.72),
                   value: model.sidebarPeek)
        .onAppear {
            pagePinned = model.sidebarVisible
            model.updateWindowButtons(); model.startEdgeWatcher(); ThreeFingerGestures.shared.start(model: model)
            DispatchQueue.main.async { model.restoreFloatOnTop() }
        }
        .onChange(of: model.sidebarWidth) { _, _ in shieldScroller() }
        .onChange(of: model.sidebarVisible) { _, pinned in
            shieldScroller()
            model.sidebarPeek = false; model.updateWindowButtons()
            let w = Metrics.sidebarWidth
            let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)
            // Скачкообразные изменения — без анимации
            func jump(_ body: () -> Void) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t, body)
            }
            if pinned {
                // Как в Orion: страница стоит неподвижно в прежней раскладке, панель въезжает поверх,
                // видимый край страницы идёт за ней; перестройка под новую ширину — один раз, в конце
                pinToken += 1
                let token = pinToken
                jump { layoutInset = 0; maskInset = 0; pagePinned = true }
                // «Логически закончилась» — не ждём, пока пружина затихнет до последнего пикселя
                withAnimation(spring, completionCriteria: .logicallyComplete) { maskInset = w } completion: {
                    guard token == pinToken else { return }
                    swapLayout(token: token, valid: { model.sidebarVisible }, jump: jump) { layoutInset = -1; maskInset = -1 }
                }
            } else {
                // Как в Orion: панель сразу уезжает поверх страницы; страница разворачивается на всю ширину,
                // как только снят её снимок (до этого открывающаяся полоса — цветом сайта)
                pinToken += 1
                let token = pinToken
                jump { layoutInset = w; maskInset = w; pagePinned = false; snapshot = nil }
                swapLayout(token: token, valid: { !model.sidebarVisible }, jump: jump) { layoutInset = 0 }
                withAnimation(spring) { maskInset = 0 } completion: {
                    if token == pinToken { jump { layoutInset = -1; maskInset = -1 } }
                }
            }
        }
        .onChange(of: model.sidebarPeek) { model.updateWindowButtons(); model.updatePageMouse() }
        .onChange(of: model.folderPeek.folderID) { model.updatePageMouse() }
        .onChange(of: model.overview.visible) { model.updatePageMouse() }
        .onChange(of: model.activeTab?.id) { model.updatePageMouse() }
    }
}

/// Всё, что всплывает поверх страницы и панели: попапы, Peek, строка команд, тосты
struct WindowOverlays: View {
    @AppStorage(Prefs.toolbar) private var toolbarOn = true
    @AppStorage(Prefs.topBar) private var topBarOn = true
    @AppStorage(Prefs.topBarStrip) private var stripOn = true
    @Environment(BrowserModel.self) private var model

    var body: some View {
        ZStack {
            SplitDropOverlay().zIndex(2)
            PaneDragOverlay().zIndex(3)
            PeekOverlay().zIndex(2)
            FolderPeekOverlay().zIndex(2)
            HoverPreviewOverlay().zIndex(3)
            if model.hostsTranslator { TranslatorHost() }
            TabOverviewView().zIndex(2)
            TabSwitcherView().zIndex(2)
            // Панель скрыта — у верхнего края плавающая капсула с навигацией (как Focus в Orion/Safari);
            // свёрнутая — тонкая полоска посередине у кромки, наведёшь — раскрывается
            // Настройки читаем здесь же (@AppStorage) — иначе после ⇧⌘L капсула не появлялась до перезагрузки
            if topBarOn && !toolbarOn && model.topLoaderShown {
                Group {
                    if model.topBarShown {
                        TopBar()
                            .transition(.asymmetric(insertion: .scale(scale: 0.4, anchor: .top).combined(with: .opacity),
                                                    removal: .scale(scale: 0.4, anchor: .top).combined(with: .opacity)))
                    } else if stripOn {
                        TopBarHandle()
                            .transition(.opacity)
                    } else {
                        // Без полоски: у кромки только загрузка (и та исчезает), капсула — по наведению на кромку
                        LoaderStrip(tab: model.activeTab, handle: false)
                            .frame(width: 120, height: 12)
                            .padding(.top, -3)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .padding(.top, Metrics.inset)
                // Панель закреплена — капсула посередине страницы, а не всего окна
                .padding(.leading, model.sidebarVisible ? Metrics.sidebarWidth : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.topBarShown)
                .zIndex(2)
            }
            if model.find.visible {
                FindBar()
                    .padding(Metrics.inset)
                    .padding(.top, PageToolbar.enabled ? PageToolbar.height : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
            if model.commandBar != nil {
                CommandBarView().zIndex(2)
            }
            // Пересказ страницы — карточкой справа сверху
            if Summarizer.shared.visible, Summarizer.shared.tabID == model.activeTab?.id {
                SummaryCard()
                    .padding(Metrics.inset)
                    .padding(.top, PageToolbar.enabled ? PageToolbar.height : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
            // Capture Image: подсказка, пока выбираешь; взятая картинка — карточкой справа сверху
            if ImageCapture.shared.picking {
                CaptureHint()
                    .padding(.top, Metrics.inset + (PageToolbar.enabled ? PageToolbar.height : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
            if ImageCapture.shared.visible, ImageCapture.shared.tabID == model.activeTab?.id {
                CaptureCard()
                    .padding(Metrics.inset)
                    .padding(.top, PageToolbar.enabled ? PageToolbar.height : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
            // Загрузки — кружок справа внизу (пока качается и ещё немного после)
            DownloadsBadge()
                .padding(Metrics.inset + DownloadsBadge.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(2)
            // Знакомство — карточка внизу у панели
            TourOverlay().zIndex(4)
            SetupOverlay().zIndex(5)
            // Инкогнито заперто (Touch ID) — заслонка поверх всего
            if model.currentSpace.isIncognito && IncognitoLock.shared.locked {
                IncognitoLockView().zIndex(10).transition(.opacity)
            }
            // Уведомления — справа сверху под полосой; если там карточка (пересказ, картинка) — справа снизу над загрузками
            let cardOpen = (Summarizer.shared.visible && Summarizer.shared.tabID == model.activeTab?.id)
                || (ImageCapture.shared.visible && ImageCapture.shared.tabID == model.activeTab?.id)
            NoticeStack(fromBottom: cardOpen)
                .padding(Metrics.inset)
                .padding(.top, cardOpen ? 0 : (PageToolbar.enabled ? PageToolbar.height : 0))
                .padding(.bottom, cardOpen ? DownloadsBadge.reserve : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cardOpen ? .bottomTrailing : .topTrailing)
                .zIndex(3)
        }
        .onChange(of: model.peek?.id) { model.updatePageMouse() }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.peek?.id)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.find.visible)
        .onChange(of: model.activeTab?.id) { model.find.retarget() }
        .onChange(of: model.activeTab?.isLoading) { if model.activeTab?.isLoading == false { model.find.retarget() } }
    }
}

/// Страница с полосой над ней (адрес, кнопки) — полоса выключается в настройках
struct PageColumn: View {
    @AppStorage(Prefs.toolbar) private var toolbar = true
    var body: some View {
        VStack(spacing: 0) {
            if toolbar { PageToolbar() }
            WebArea()
        }
    }
}

// MARK: - Цвета выделения

/// Затемнение фона панели (в тёмной теме — наоборот, подсветка).
func sidebarShade(_ amount: Double) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(amount * 0.7)
            : NSColor.black.withAlphaComponent(amount)
    })
}

/// Активная вкладка: цвет панели, темнее её фона примерно на 15–20%.
struct ActiveFill: View {
    let space: Space
    var radius: CGFloat? = nil
    @Environment(\.rowCorner) private var corner
    var body: some View {
        let radius = self.radius ?? corner
        RoundedRectangle(cornerRadius: radius, style: .circular).fill(space.tint.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .circular).fill(sidebarShade(0.09)))
    }
}

/// Кусок общей рамки выделения: у соседних выделенных вкладок рамка сливается в одну.
struct SelectionSegment: View {
    let space: Space
    let top: Bool
    let bottom: Bool
    let gapBelow: CGFloat
    var radius: CGFloat? = nil
    var active = false
    @Environment(\.rowCorner) private var corner

    var body: some View {
        let radius = self.radius ?? corner
        let ext: CGFloat = radius + 8
        Color.clear
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .circular)
                    .fill(space.tint.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .circular).fill(sidebarShade(active ? 0.12 : 0.05)))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .circular).strokeBorder(space.tintStrong.opacity(0.45), lineWidth: 1.5))
                    // внутренние края уводим за обрезку — остаются только внешние
                    .padding(.top, top ? 0 : -ext)
                    .padding(.bottom, bottom ? 0 : -ext)
            }
            .clipped()
            // Обрезка — уже с промежутком до следующей выделенной вкладки: заливка его перекрывает, щели нет
            .padding(.bottom, -gapBelow)
            .allowsHitTesting(false)
    }
}

// MARK: - Узкий режим панели: колонка значков

struct CompactSidebar: View {
    @Environment(BrowserModel.self) private var model
    static let cell: CGFloat = 32          // единая сетка узкой колонки

    var body: some View {
        let sp = model.currentSpace
        VStack(spacing: 4) {
            // Вверху — развернуть панель обратно
            Button {
                model.toggleCompactSidebar()
            } label: {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
                    .frame(width: Self.cell, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Expand sidebar")
            .contextMenu {
                Button("Expand Sidebar") { model.toggleCompactSidebar() }
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
            }
            .padding(.top, 10)
            .reportFrame { model.drag.navZone = $0 }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(model.favorites) { FavoriteCell(tab: $0) }
                    if !sp.pinned.isEmpty {
                        VStack(spacing: 4) { ForEach(sp.pinned) { PinnedCell(tab: $0) } }
                            .padding(.vertical, 2)
                            .background { PinZoneHint(space: sp, round: true) }
                            .reportFrame { model.drag.pinnedZone = $0 }
                    } else if PinZoneHint.showsPlaceholder(model) {
                        PinDropPlaceholder(round: true)
                            .reportFrame { model.drag.pillZone = $0 }
                    }
                    if !(model.favorites.isEmpty && sp.pinned.isEmpty) {
                        Divider().frame(width: 20).padding(.vertical, 4)
                    }
                    ForEach(sp.savedEntries) { e in
                        switch e {
                        case .folder(let f): FolderBlock(folder: f, space: sp, compact: true)
                        case .tab(let t):
                            CompactTabCell(tab: t)
                            if t.branchesExpanded { ForEach(sp.branches(of: t)) { CompactTabCell(tab: $0).opacity(0.7) } }
                        }
                    }
                    if !sp.savedEntries.isEmpty && !sp.tempEntries.isEmpty {
                        Divider().frame(width: 20).padding(.vertical, 4)
                    }
                    ForEach(sp.tempEntries) { e in
                        switch e {
                        case .folder(let f): FolderBlock(folder: f, space: sp, compact: true)
                        case .tab(let t): CompactTabCell(tab: t)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)   // место для выреза активной вкладки у краёв
                .reportFrame { model.drag.favZone = .zero; _ = $0 }
            }
            .reportFrame { model.drag.listZone = $0 }
            if Module.miniPlayer.isOn { MiniPlayerCell() }
            Button { model.showCommandBar(.newTab) } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                    .frame(width: Self.cell, height: Self.cell).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("New Tab — ⌘T")
            // Все пространства столбиком; текущее подсвечено
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { i, s in
                let current = s.id == sp.id
                Button { model.swipe.switchTo(i, model: model) } label: {
                    Image(systemName: current ? Symbols.filled(s.icon) : Symbols.open(s.icon))
                        .font(.system(size: 13))
                        .foregroundStyle(current ? s.iconColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(current ? Color.primary.opacity(0.1) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(s.name)
                .reportFrame { model.drag.spaceFrames[s.id] = $0 }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
        .background(WindowDragArea())
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear.onAppear { model.swipe.sidebarRect = f }.onChange(of: f) { model.swipe.sidebarRect = f }
        })
        .overlay { DropIndicator() }
        .overlay { DragGhost() }
        .coordinateSpace(name: TabDrag.space)
    }
}

/// Выезд панели: быстро доезжает с небольшим перелётом и мягко возвращается на место —
/// один отскок, без качания туда-обратно, как у обычной пружины.
struct PeekBounce: CustomAnimation {
    static let approach = 0.16                 // доезд до перелёта
    static let overshoot = 0.03                // перелёт — доля пути
    static let settle = 30.0                   // как быстро возвращается на место (без недолёта)
    static let total = 0.38

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < Self.total else { return nil }
        return value.scaled(by: Self.progress(time))
    }

    static func progress(_ t: Double) -> Double {
        if t < approach {
            let u = t / approach
            return (1 + overshoot) * (1 - pow(1 - u, 3))
        }
        let s = t - approach
        return 1 + overshoot * (1 + settle * s) * exp(-settle * s)
    }
}

/// Колонка с вырезом под активную вкладку: через вырез видна сама страница,
/// у края колонки — плавные скругления (тень колонки обходит вырез, шва нет).
/// Маска тени карточки: всё видно, кроме выреза активной вкладки — там тень гаснет,
/// оставаясь только мягкой полосой у правого края панели (где вкладка переходит в страницу)
struct CompactColumnShape: Shape {
    var radius: CGFloat
    var notch: CGRect?
    /// Вырезать ли сейчас: рамка выреза остаётся (и анимируется) и когда его не видно
    var on = true
    /// Вырез двигается плавно (вместе со строкой вкладки)
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { let n = notch ?? .zero; return .init(.init(n.minX, n.minY), .init(n.width, n.height)) }
        set {
            guard notch != nil else { return }
            notch = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second)
        }
    }
    func path(in r: CGRect) -> Path {
        // Капсула: верх и низ полукругом на всю ширину колонки
        let base = RoundedRectangle(cornerRadius: min(radius, r.width / 2), style: .circular).path(in: r)
        guard on, let n = notch, n.width > 4 else { return base }
        let cut = PageTongue(row: n, edge: r.maxX, radius: n.height / 2, fillet: 6).path(in: r)
        return base.subtracting(cut)
    }
}

/// Вкладка в узкой панели — фавикон в круге 32 pt.
struct CompactTabCell: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    @State private var rowID = UUID()
    @State private var globalFrame: CGRect = .zero
    @State private var hover = false

    var body: some View {
        let sp = model.currentSpace
        if !tab.isPinned, let g = sp.group(of: tab.id), let lead = sp.splitLead(of: tab) {
            if lead === tab { CompactSplitCell(group: g) }
        } else {
            cell
        }
    }

    @ViewBuilder private var cell: some View {
        let sp = model.currentSpace
        let visible = model.isVisible(tab)
        let selected = model.selection.contains(tab)
        let dragging = model.drag.ids.contains(tab.id) && model.drag.active
        // Закреплённая колонка и известен цвет страницы — вкладку показывает вырез в колонке
        let notched = visible && model.sidebarVisible && model.activeTab === tab && tab.pageColor != nil
        Favicon(url: tab.url)
            .frame(width: 18, height: 18)
            .opacity(tab.asleep && !visible ? 0.55 : 1)
            .overlay(alignment: .topTrailing) { ProfileBadge(tab: tab).offset(x: 3, y: -3) }
            .overlay(alignment: .bottomTrailing) { SoundBadge(tab: tab).offset(x: 6, y: 6) }
            .frame(width: CompactSidebar.cell, height: CompactSidebar.cell)
            .background {
                if selected {
                    Circle().fill(sp.tint.opacity(0.22)).overlay(Circle().strokeBorder(sp.tintStrong.opacity(0.8), lineWidth: 1.5))
                } else if notched {
                    EmptyView()
                } else if visible {
                    // Выезжающая узкая панель (или цвет страницы ещё неизвестен) — активная выделена кругом
                    Circle().fill(sp.tint.opacity(0.3)).overlay(Circle().fill(sidebarShade(0.09)))
                } else if hover {
                    Circle().fill(sidebarShade(0.06))
                }
            }
            .opacity(dragging ? 0.35 : 1)
            .contentShape(Circle())
            .onTapGesture { model.selection.click(tab, model: model) }
            .tabDrag(tab, model: model)
            .reportFrame { f in
                model.drag.rowFrames[tab.id] = f
                if model.activeTab === tab { model.activeRow.set(tab.id, f, compact: true, owner: rowID) }
            }
            .onChange(of: model.activeTab === tab) { _, isActive in
                if isActive, let f = model.drag.rowFrames[tab.id] { model.activeRow.set(tab.id, f, compact: true, owner: rowID) }
                else if !isActive { model.activeRow.clear(tab.id, compact: true, owner: rowID) }
            }
            .onDisappear { model.activeRow.clear(tab.id, compact: true, owner: rowID); model.hoverPreview.hover(tab, frame: .zero, on: false, model: model) }
            .background(GeometryReader { g in
                let f = g.frame(in: .global)
                Color.clear.onAppear { globalFrame = f }.onChange(of: f) { globalFrame = f }
            })
            .onHover { h in
                hover = h
                model.hoverPreview.hover(tab, frame: globalFrame, on: h, model: model)
            }
            .simultaneousGesture(TapGesture().onEnded { model.hoverPreview.hide() })
            .contextMenu {
                if selected && model.selection.ids.count > 1 { GroupMenu() } else { TabMenu(tab: tab) }
            }
            .help(tab.displayTitle)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Папка в списке

/// Раскрытая папка — один затемнённый блок: шапка и её вкладки с небольшим отступом.
struct FolderBlock: View {
    @Environment(BrowserModel.self) private var model
    let folder: Folder
    let space: Space
    var compact = false
    /// Уровень вложенности: вложенная папка — блоком внутри подложки родителя
    var depth = 0
    @Environment(\.rowCorner) private var corner

    var body: some View {
        let f = folder
        // Свёрнутая папка показывает свои открытые вкладки (не спящие) и ту, что на экране
        let isOpen: (Tab) -> Bool = { !$0.asleep || model.isVisible($0) }
        let openTab = space.allTabs(in: f).contains(where: isOpen)
        // Вложенная папка без содержимого под заголовком — просто строка (без подложки): иначе её блок
        // выходил выше и шире строк родителя и казался крупнее самой папки, в которой лежит
        let hasBelow = f.expanded ? !(space.subfolders(of: f).isEmpty && space.mainTabs(in: f).allSatisfy { space.hiddenInSplit($0) }) : openTab
        let framed = depth > 0 ? hasBelow : (f.expanded || openTab)
        let dragging = model.drag.folderDrag == f.id && model.drag.active
        VStack(spacing: 2) {
            FolderHeader(folder: f, compact: compact)
            if f.expanded {
                // Вложенные папки — сверху, над вкладками этой папки
                ForEach(space.subfolders(of: f)) { sub in
                    FolderBlock(folder: sub, space: space, compact: compact, depth: depth + 1)
                }
                ForEach(space.mainTabs(in: f)) { t in
                    if compact {
                        CompactTabCell(tab: t)
                        if t.branchesExpanded { ForEach(space.branches(of: t)) { CompactTabCell(tab: $0).opacity(0.7) } }
                    } else {
                        TabWithBranches(tab: t, space: space, indent: 10)
                    }
                }
            } else {
                // Папка свёрнута, но её открытые вкладки (и из вложенных) остаются видны под заголовком
                ForEach(space.allTabs(in: f).filter(isOpen)) { t in
                    if compact { CompactTabCell(tab: t) } else { TabRow(tab: t, indent: 10) }
                }
            }
        }
        // Шапка папки не сдвигается при раскрытии: подложка выходит за её края наружу,
        // а место под нижний край подложки добавляется только снизу
        .padding(.bottom, framed ? 4 : 0)
        // В узкой колонке — узкая капсула по ширине ячейки (+4 по бокам): полукруглые торцы концентричны кругам вкладок
        .frame(width: compact ? CompactSidebar.cell + 8 : nil)
        .background {
            // Подложка — у раскрытой папки и у свёрнутой, из которой открыта вкладка (видно, чья она)
            if framed {
                // Активная вкладка этой папки соединена со страницей вырезом — подложку папки под ним вырезаем
                // (маска — на саму подложку, до выхода её за края: иначе она обрезала бы запас подложки)
                if compact {
                    Capsule().fill(sidebarShade(Metrics.blockShade))
                        .mask { FolderNotchMask(folder: f) }
                        .padding(.top, -4)
                } else {
                    // Строки внутри — с равным отступом 4 со всех сторон; скругление = скругление строки + отступ
                    // (центры дуг совпадают), до края панели — те же 6, что и везде
                    // Вложенная папка стоит на месте строки родителя (на 4 внутри его подложки) — её скругление
                    // как у строк родителя, а у её строк — ещё на 4 меньше: все дуги с общим центром
                    RoundedRectangle(cornerRadius: blockRadius, style: .circular).fill(sidebarShade(Metrics.blockShade))
                        .mask { FolderNotchMask(folder: f) }
                        .padding(.horizontal, -4).padding(.top, -4)
                }
            }
        }
        // Подложка выходит над заголовком на 4 — запас сверху 4 (всегда, чтобы заголовок не прыгал при раскрытии):
        // между подсветкой строки над папкой и подложкой тот же зазор 2, что между строками
        .padding(.top, 4)
        // Строки внутри подложки — со скруглением на 4 меньше её
        .environment(\.rowCorner, framed && !compact ? max(blockRadius - 4, 4) : corner)
        // Вложенная папка с подложкой: подложка — на месте строки родителя, содержимое — на 4 внутри неё.
        // Без подложки — обычная строка, вровень с остальными
        .padding(.horizontal, depth > 0 && framed && !compact ? 4 : 0)
        .opacity(dragging ? 0.35 : 1)
    }

    /// Скругление подложки: у папки верхнего уровня — строка + 4, у вложенной — как у строк родителя
    private var blockRadius: CGFloat { depth == 0 ? corner + 4 : corner }
}

// MARK: - Ручка ширины панели

struct SidebarResizeHandle: View {
    @Environment(BrowserModel.self) private var model
    let edge: CGFloat
    @State private var start: CGFloat?
    /// Зона захвата: 5 pt внутрь панели и 9 pt на страницу — курсор обычно подходит со стороны страницы
    static let inside: CGFloat = 5, outside: CGFloat = 9

    var body: some View {
        ResizeCursorArea()
            .frame(width: Self.inside + Self.outside)
            .frame(maxHeight: .infinity)
            .padding(.vertical, Metrics.windowRadius * 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = model.sidebarWidth }
                    let r = Metrics.sidebarWidthRange
                    let raw = (start! + v.translation.width).rounded()   // целые точки: дробная ширина страницы даёт белый пиксель справа
                    // Сильно поджали — панель защёлкивается в узкую колонку значков; потянули обратно — в обычную
                    let w: CGFloat = raw < 150 ? Metrics.compactWidth : min(max(raw, r.lowerBound), r.upperBound)
                    if w != Metrics.compactWidth { model.lastSidebarWidth = w }
                    if (w == Metrics.compactWidth) != (model.sidebarWidth == Metrics.compactWidth) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.sidebarWidth = w }
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    } else {
                        model.sidebarWidth = w
                    }
                }
                .onEnded { _ in
                    start = nil
                    UserDefaults.standard.set(Double(model.sidebarWidth), forKey: "sidebarWidth")
                })
            // Двойной клик — стандартная ширина
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.sidebarWidth = Metrics.defaultSidebarWidth }
                UserDefaults.standard.set(Double(Metrics.defaultSidebarWidth), forKey: "sidebarWidth")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, max(0, edge - Self.inside))
    }
}

/// Курсор ↔ закреплён за зоной на уровне окна — страница под ней его не перебивает.
struct ResizeCursorArea: NSViewRepresentable {
    final class V: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // клики и перетаскивание — жесту SwiftUI
        override func layout() { super.layout(); window?.invalidateCursorRects(for: self) }
        // Страница под зоной сама ставит свой курсор на каждое движение — ставим наш после неё
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited,
                                                                   .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with e: NSEvent) { DispatchQueue.main.async { NSCursor.resizeLeftRight.set() } }
        override func mouseEntered(with e: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func cursorUpdate(with e: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) { v.window?.invalidateCursorRects(for: v) }
}

// MARK: - Светофор (свой, живёт внутри панели и ездит вместе с ней)

struct TrafficLights: View {
    static let size: CGFloat = 12
    var vertical = false
    /// Чьё окно (nil — главное окно браузера)
    var target: NSWindow? = nil
    @Environment(\.controlActiveState) private var active
    @Environment(BrowserModel.self) private var model
    @State private var hover = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            light(Color(red: 1, green: 0.37, blue: 0.34), "xmark") { (target ?? model.mainWindow)?.performClose(nil) }
            light(Color(red: 1, green: 0.74, blue: 0.18), "minus") { (target ?? model.mainWindow)?.miniaturize(nil) }
            light(Color(red: 0.16, green: 0.78, blue: 0.25), "arrow.up.left.and.arrow.down.right") {
                (target ?? model.mainWindow)?.toggleFullScreen(nil)
            }
        }
        .onHover { hover = $0 }
    }

    private func light(_ color: Color, _ glyph: String, action: @escaping () -> Void) -> some View {
        let on = active == .key || hover
        return Button(action: action) {
            Circle()
                // Неактивное окно — серые кружки с обводкой, как у системного светофора (видны и на светлой панели)
                .fill(on ? color : Color.primary.opacity(0.22))
                .overlay(Circle().stroke(Color.black.opacity(on ? 0.12 : 0.18), lineWidth: 0.5))
                .overlay {
                    if hover {
                        Image(systemName: glyph)
                            .font(.system(size: glyph == "minus" || glyph == "xmark" ? 7 : 6, weight: .bold))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // без синей рамки фокуса
    }
}

// MARK: - Край окна, за который его можно тащить

/// Тонкая полоска у края, за которую окно можно тащить мышью (двумя пальцами — у верхнего края, см. SpaceSwipe).
struct DragEdge: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis

    var body: some View {
        WindowDragArea()
            .frame(width: axis == .vertical ? 10 : nil, height: axis == .horizontal ? 10 : nil)
    }
}

/// Загрузка под верхней гранью страницы.
/// Пока грузится — две половинки ползут с краёв к центру: плавно, с прогнозом по скорости загрузки
/// (движок сообщает прогресс рывками — между ними половинки продолжают ехать сами, замедляясь у середины).
/// Догрузилась — половинки разгоняются и врезаются друг в друга, сплющиваются и сливаются в линию потолще;
/// линия стягивается с обоих концов к центру в точку, точка хлопает (подпрыгивает в размере) и исчезает.
/// Анимация целиком на Core Animation — её рисует система, и она не дёргается, когда приложение занято
/// (а в момент окончания загрузки оно занято всегда: заголовок, значок, превью, история).
struct LoadingBar: View {
    let tab: Tab
    /// Показывать всегда (сплит, Peek); иначе — только когда загрузку не показывает капсула сверху
    var always = false
    @Environment(BrowserModel.self) private var model
    /// Чтобы полоса перерисовывалась, когда полосу над страницей или капсулу прячут / возвращают
    @AppStorage(Prefs.toolbar) private var toolbarOn = true
    @AppStorage(Prefs.topBar) private var topBarOn = true
    var body: some View {
        // Над страницей (адрес виден): отрезки у краёв, в конце — кружок с отскоком и исчезает
        if always || !(topBarOn && !toolbarOn && model.topLoaderShown) {
            LoaderStrip(tab: tab, handle: false)
                .frame(width: 160, height: 14)
                .allowsHitTesting(false)
        }
    }
}

private struct LoadingBarLayer: NSViewRepresentable {
    let loading: Bool
    let progress: Double
    func makeNSView(context: Context) -> LoadingBarView { LoadingBarView() }
    func updateNSView(_ v: LoadingBarView, context: Context) { v.update(loading: loading, progress: progress) }
}

final class LoadingBarView: NSView {
    static let size = CGSize(width: 160, height: 14)
    static let track: CGFloat = 120      // от края до края
    static let piece: CGFloat = 24       // длина половинки
    static let lineY: CGFloat = 6.5      // середина черты от верха

    private let left = CALayer(), right = CALayer(), merged = CALayer()
    private var loading = false
    private var rate = 0.5               // оценка скорости загрузки, долей в секунду
    private var lastValue = 0.0, lastValueT = 0.0
    private var p = 0.0                  // куда половинки едут сейчас (0 — у краёв, 1 — встретились)
    private var run = 0

    private var half: CGFloat { Self.track / 2 - Self.piece }
    private var cx: CGFloat { Self.size.width / 2 }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        for l in [left, right, merged] {
            l.backgroundColor = NSColor.controlAccentColor.cgColor
            l.opacity = 0
            l.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(),
                         "transform": NSNull(), "cornerRadius": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
        }
        for l in [left, right] {
            l.bounds = CGRect(x: 0, y: 0, width: Self.piece, height: 3)
            l.cornerRadius = 1.5
        }
        place(gap: half)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for l in [left, right, merged] { l.backgroundColor = NSColor.controlAccentColor.cgColor }
        }
    }

    private func x(_ gap: CGFloat, _ side: CGFloat) -> CGFloat { cx + side * (gap + Self.piece / 2 + 0.5) }

    private func place(gap: CGFloat) {
        left.position = CGPoint(x: x(gap, -1), y: Self.lineY)
        right.position = CGPoint(x: x(gap, 1), y: Self.lineY)
    }

    /// Где половинки на экране прямо сейчас (с учётом идущей анимации)
    private var currentGap: CGFloat {
        let px = (left.presentation() ?? left).position.x
        return max(0, cx - px - Self.piece / 2 - 0.5)
    }

    func update(loading now: Bool, progress: Double) {
        if now && !loading { start() }
        if now {
            let t = CACurrentMediaTime()
            if progress > lastValue, t > lastValueT, lastValueT > 0 {
                rate = min(3, max(0.05, rate * 0.7 + (progress - lastValue) / (t - lastValueT) * 0.3))
            }
            if progress != lastValue { lastValue = progress; lastValueT = t }
            glide(progress)
        } else if loading {
            finish()
        }
        loading = now
    }

    private func start() {
        run += 1
        layer?.removeAllAnimations()
        for l in [left, right, merged] { l.removeAllAnimations() }
        p = 0; rate = 0.5; lastValue = 0; lastValueT = CACurrentMediaTime()
        merged.opacity = 0
        left.opacity = 1; right.opacity = 1
        place(gap: half)
    }

    /// Пока грузится: едем к точке, где загрузка, по прогнозу, будет через секунду; у середины замедляемся.
    /// Каждое новое сообщение о прогрессе продолжает движение с текущего места — без рывков.
    private func glide(_ progress: Double) {
        let cap = 0.9
        let ahead = min(cap, max(p, progress) + rate * 1.0 * max(0, 1 - progress / cap))
        let target = min(cap, max(ahead, min(progress, cap)))
        guard target > p + 0.001 else { return }
        p = target
        let from = currentGap, to = half * CGFloat(1 - target)
        for (l, side) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = x(from, side); a.toValue = x(to, side)
            a.duration = 1.0
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.35, 1)   // мягко тормозит
            l.position.x = x(to, side)
            l.add(a, forKey: "glide")
        }
    }

    private func finish() {
        let g0 = currentGap
        for l in [left, right] { l.removeAnimation(forKey: "glide"); l.position.x = x(g0, l === left ? -1 : 1) }
        let hit = 0.12, pullStart = 0.14, pull = 0.2, pop = 0.26
        let total = hit + pullStart + pull + pop
        let n = 90
        var lx: [CGFloat] = [], rx: [CGFloat] = [], pieceOn: [Float] = [], lineOn: [Float] = []
        var w: [CGFloat] = [], h: [CGFloat] = [], sc: [CGFloat] = [], times: [NSNumber] = []
        let full = Self.piece * 2, thick: CGFloat = 5
        for i in 0...n {
            let τ = total * Double(i) / Double(n)
            times.append(NSNumber(value: τ / total))
            if τ < hit {
                // 1. Разгон навстречу — с ускорением, чтобы удар был сильным
                let u = τ / hit
                let g = g0 * CGFloat(1 - u * u * u)
                lx.append(x(g, -1)); rx.append(x(g, 1)); pieceOn.append(1); lineOn.append(0)
                w.append(full); h.append(3); sc.append(1)
                continue
            }
            let u = τ - hit
            // 2. Удар: линия сплющивается по длине и раздувается в толщину, затухающе качаясь
            let squash = exp(-13 * u) * cos(2 * .pi * u / 0.16)
            // 3. Стягивание обоих концов к центру в точку
            let k = min(1, max(0, (u - pullStart) / pull))
            let ease = k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
            var width = full + (thick - full) * CGFloat(ease)
            width -= 16 * CGFloat(squash) * (width / full)
            let height = thick + 3 * CGFloat(max(0, squash)) * CGFloat(1 - ease)
            // 4. Точка хлопает и исчезает: быстрый подскок и сжатие в ноль
            var scale: CGFloat = 1
            if u > pullStart + pull {
                let v = min(1, (u - pullStart - pull) / pop)
                scale = v < 0.3 ? 1 + 0.7 * CGFloat(1 - pow(1 - v / 0.3, 2))
                                : 1.7 * CGFloat(1 - pow((v - 0.3) / 0.7, 2))
            }
            lx.append(x(0, -1)); rx.append(x(0, 1)); pieceOn.append(0); lineOn.append(1)
            w.append(max(height, width)); h.append(height); sc.append(max(0.001, scale))
        }
        func kf(_ path: String, _ values: [Any], discrete: Bool = false) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values; a.keyTimes = times; a.duration = total
            a.calculationMode = .linear   // резкие 0↔1 в соседних точках — практически мгновенно
            return a
        }
        merged.position = CGPoint(x: cx, y: Self.lineY)
        CATransaction.begin()
        let r = run
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.run == r, !self.loading else { return }
            for l in [self.left, self.right, self.merged] { l.opacity = 0 }
        }
        left.add(kf("position.x", lx), forKey: "finale-x")
        right.add(kf("position.x", rx), forKey: "finale-x")
        left.add(kf("opacity", pieceOn, discrete: true), forKey: "finale-o")
        right.add(kf("opacity", pieceOn, discrete: true), forKey: "finale-o")
        merged.add(kf("opacity", lineOn, discrete: true), forKey: "finale-o")
        merged.add(kf("bounds.size.width", w), forKey: "finale-w")
        merged.add(kf("bounds.size.height", h), forKey: "finale-h")
        merged.add(kf("cornerRadius", h.map { $0 / 2 }), forKey: "finale-r")
        merged.add(kf("transform.scale", sc), forKey: "finale-s")
        // Итоговое состояние — всё скрыто (анимации кончатся — останется оно)
        left.opacity = 0; right.opacity = 0; merged.opacity = 0
        merged.bounds = CGRect(x: 0, y: 0, width: thick, height: thick)
        CATransaction.commit()
    }
}

struct EmptyStart: View {
    @Environment(BrowserModel.self) private var model
    @State private var tip = Int.random(in: 0..<1000)
    @State private var tips = EmptyStart.makeTips()

    /// Подсказки: с текущими сочетаниями клавиш (своих нет — подсказка не показывается), только включённые модули
    static func makeTips() -> [String] {
        let s = Shortcuts.shared
        func k(_ id: ShortcutID, _ text: String) -> String? {
            let key = s.text(id)
            return key.isEmpty ? nil : text.replacingOccurrences(of: "{k}", with: key)
        }
        var list: [String?] = [
            k(.newTab, "{k} — new tab"),
            "Try “!yt cats” or “!w Minsk” in the command bar",
            k(.reopenClosed, "Closed a tab by mistake? {k} brings it back"),
            k(.undo, "{k} undoes tab actions — closing, moving, clearing"),
            k(.archive, "Temporary tabs go to the archive, not away — {k}"),
            "Tabs below “Temp” archive themselves — drag one above the line to keep it",
            "Hold the pointer on “Temp” — it turns into “Clear”",
            "A red dot on a tab means it goes to the archive within an hour",
            "Folders can be temporary too: make one below “Temp”",
            k(.overview, "{k} shows all tabs at once"),
            "⌃Tab switches to the previous tab — hold ⌃ to see more",
            "With the pointer over the sidebar, ↑ and ↓ switch tabs",
            k(.toolbar, "{k} hides the toolbar — the address waits at the top edge"),
            "Drag toolbar buttons to reorder them; right-click one to hide it",
            k(.splitNew, "{k} opens a split — up to four pages side by side"),
            "Drop a tab onto the page to open it in a split",
            k(.littleWindow, "{k} opens a little window — links from other apps land there"),
            k(.floatOnTop, "{k} keeps the window above all others"),
            k(.reader, "{k} — Reader: just the article, your font and theme"),
            k(.translate, "{k} translates the page right on your Mac"),
            k(.copyLink, "{k} copies the address of the page"),
            k(.copyMarkdown, "{k} copies the link as Markdown"),
            k(.incognito, "{k} — incognito: nothing is written to disk"),
            "Swipe with two fingers across the sidebar to switch spaces",
            "Each space can have its own profile — its own sign-ins and cookies",
            "Right-click a link → “Open Link As” — another profile or a throwaway container",
            "The gear in the address bar holds site settings: zoom, blocker, permissions",
            k(.compactSidebar, "{k} turns the sidebar into a narrow column of icons"),
            k(.newWindow, "{k} opens a new window — each window shows its own space"),
            "Keyboard shortcuts are yours to change: Settings → Shortcuts",
            "Settings → Modules: what’s off costs nothing",
        ]
        if Module.summarize.isOn { list.append(k(.summarize, "{k} summarizes the page — and answers questions about it")) }
        if Module.capture.isOn { list.append(k(.captureImage, "{k} takes any picture on a page at full size")) }
        if Module.peek.isOn { list.append("Links from pinned tabs to other sites open as a card — Peek") }
        if Module.autoReload.isOn { list.append("A tab can reload itself: “⋯” → Auto Reload") }
        if Module.miniPlayer.isOn { list.append("Music or video from another tab keeps playing in the mini player") }
        return list.compactMap { $0 }
    }
    var body: some View {
        VStack(spacing: 10) {
            // Камень Sapfire: крутится, тянешь — поворачивается, клик — новая вкладка.
            // Полный оборот или подкрутка мышью — следующая подсказка
            GemView(onTap: { model.showCommandBar(.newTab) },
                    onTurn: { withAnimation(.easeInOut(duration: 0.5)) { tip += 1 } })
                .frame(width: 170, height: 170)
            // Подсказки о Sapfire — по одной; сменяются с каждым оборотом камня, от подкрутки и по клику
            Text(tips.isEmpty ? "" : tips[tip % tips.count])
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)
                .id(tip)
                .transition(.opacity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { tip += 1 } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.showCommandBar(.newTab) }
    }
}

// MARK: - Боковая панель

struct Sidebar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        if Metrics.compact { CompactSidebar() } else { fullBody }
    }

    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    @AppStorage(Prefs.toolbar) private var toolbarOn = true
    /// Центр скругления верхних углов панели (от её края): там стоит первый кружок светофора
    private var cornerCenter: CGFloat {
        let card = !model.sidebarVisible || sidebarStyle == "floating"
        return Metrics.windowRadius - (card ? Metrics.inset : 0)
    }

    private var fullBody: some View {
        let sp = model.currentSpace
        return VStack(alignment: .leading, spacing: 8) {
            // Верхний ряд: место под «светофор» окна, имя пространства и кнопка панели
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                // Полоса над страницей: спрятать (Focus — адрес внизу панели) или вернуть
                NavButton(icon: toolbarOn ? "rectangle.topthird.inset.filled" : "rectangle") { PageToolbar.toggle() }
                    .help(toolbarOn ? "Hide toolbar — \(Shortcuts.shared.text(.toolbar))" : "Show toolbar — \(Shortcuts.shared.text(.toolbar))")
                NavButton(icon: "sidebar.left") { model.sidebarVisible.toggle() }
                    .contextMenu {
                        Button("Compact Sidebar") { model.toggleCompactSidebar() }
                        Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                    }
            }
            // Ряд на одной горизонтали со светофором; центр «обновить» — в центре скругления правого верхнего угла
            .frame(height: 20)
            .padding(.top, cornerCenter - 10)
            // Правая кнопка — в 26 от правого края панели (как центр скругления угла окна); 13 — половина кнопки, 10 — поле панели
            .padding(.trailing, Metrics.windowRadius - 13 - 10)
            .padding(.leading, 70)
            // Профиль — по центру ширины панели (поверх ряда, между светофором и кнопками)
            .overlay {
                SpaceNameChip()
                    .frame(maxWidth: max(0, Metrics.sidebarWidth - 2 * 86))
                    .padding(.top, cornerCenter - 10)
            }
            .reportFrame { model.drag.navZone = $0 }

            // Пространства — наверху (адрес с навигацией — внизу панели)
            SpaceBar()

            // «Избранное» — общее для всех пространств, поэтому не едет при свайпе
            if !model.favorites.isEmpty {
                HoneycombLayout(diameter: FavoriteCell.diameter + 6, gap: 6) {
                    ForEach(model.favorites) { FavoriteCell(tab: $0) }
                }
                .frame(maxWidth: .infinity)
                .reportFrame { model.drag.favZone = $0 }
                .padding(.vertical, 2)
            }

            // Содержимое пространства — едет за пальцами при горизонтальном свайпе.
            // Отдельный блок со «своим» пространством: уходящее при смене пространства
            // дорисовывается со своими закрепами и вкладками, а не с данными нового
            SpaceSlider(sp: sp)

            Button { model.showCommandBar(.newTab) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Tab")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)   // по центру ширины панели
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Играет в другой вкладке — мини-плеер (под «New Tab»: кнопка не прыгает, когда плеер появляется)
            if Module.miniPlayer.isOn {
                // Внизу панели — на том же отступе 6 от низа, что и от боков (углы концентричны)
                MiniPlayerCard(outerRadius: cornerCenter).padding(.bottom, toolbarOn ? -4 : 0)
            }

            // Скругления строки (капсула, радиус 16) концентричны нижним углам панели:
            // центр дуги строки — в центре дуги угла панели (у карточки угол 20 — строка ближе к краям)
            // Адрес — здесь, только если полоса над страницей выключена (Settings → Tabs)
            if !toolbarOn {
                AddressPill()
                    .padding(.horizontal, cornerCenter - 16 - 10)
                    .padding(.bottom, cornerCenter - 16 - 10)
            }
        }
        .padding(.horizontal, Metrics.sidebarPad)
        .padding(.bottom, Metrics.sidebarPad)
        .background(WindowDragArea())   // пустые места панели двигают окно
        .reportFrame { model.drag.bounds = $0 }
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear.onAppear { model.swipe.sidebarRect = f }.onChange(of: f) { model.swipe.sidebarRect = f }
        })
        .overlay { DropIndicator() }
        .overlay { EdgeHint().animation(.easeOut(duration: 0.15), value: model.drag.edge) }
        .overlay { DragGhost() }
        .coordinateSpace(name: TabDrag.space)
        .onChange(of: model.currentSpaceID) { model.selection.clear() }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: MiniPlayer.shared.tab(model)?.id)
    }
}

/// Смена пространства: уходящее и новое рисуются целиком и едут рядом (своя анимация вместо
/// встроенного «вытеснения» — оно на первых кадрах теряло у уходящего часть кружков и строк)
struct SpaceSlider: View {
    @Environment(BrowserModel.self) private var model
    let sp: Space
    @State private var leaving: Space?
    @State private var dir: CGFloat = 1
    @State private var from: CGFloat = 0       // где было уходящее в момент смены
    @State private var leaveT: CGFloat = 1     // 0→1: старое уезжает и гаснет (первый этап)
    @State private var enterT: CGFloat = 1     // 0→1: новое въезжает и проявляется (второй этап)
    @State private var run = 0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let drag = model.swipe.offset
            ZStack(alignment: .top) {
                // Уходящее: едет дальше в свою сторону и гаснет — до того, как появится новое
                if let old = leaving {
                    SpaceContent(sp: old)
                        .padding(.horizontal, 4)
                        .offset(x: from + (-dir * w * 0.35 - from) * leaveT)
                        .opacity(Double(fade(from, w) * (1 - leaveT)))
                        .allowsHitTesting(false)
                        .id("leaving-\(old.id)")
                        .transition(.identity)
                }
                // Новое: въезжает с небольшого сдвига и проявляется. Пока тащишь пальцами — едет за ними
                // и гаснет по мере сдвига (соседа нет — только пружинит)
                SpaceContent(sp: sp)
                    .padding(.horizontal, 4)
                    .offset(x: leaving == nil ? drag : dir * 40 * (1 - enterT))
                    .opacity(Double(leaving == nil ? (model.swipe.neighborID == nil ? 1 : fade(drag, w)) : enterT))
                    .id(sp.id)
                    .transition(.identity)      // без встроенного растворения — смену рисуем сами
            }
            .frame(width: w + 8, height: g.size.height)
            .clipped()
            .offset(x: -4)
        }
        .onChange(of: sp.id) { oldID, _ in
            guard let old = model.spaces.first(where: { $0.id == oldID }) else { return }
            run += 1
            let r = run
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                leaving = old
                dir = model.swipe.direction >= 0 ? 1 : -1
                from = model.swipe.releaseOffset
                leaveT = 0; enterT = 0
            }
            withAnimation(.easeIn(duration: 0.13)) { leaveT = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                guard r == run else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { enterT = 1 }
            }
            // Уходящее (уже невидимое) держим, пока новое не встанет на место
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if r == run { leaving = nil } }
        }
    }

    /// Непрозрачность по сдвигу: к трети ширины панели — в ноль
    private func fade(_ x: CGFloat, _ w: CGFloat) -> CGFloat {
        max(0, 1 - abs(x) / max(1, w * 0.33))
    }
}

/// Закреплённые и список вкладок одного пространства
struct SpaceContent: View {
    @Environment(BrowserModel.self) private var model
    let sp: Space

    var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        // Закреплённые (если их нет — зоной для закрепления служит строка адреса). В инкогнито их нет
        if sp.isIncognito {
        } else if !sp.pinned.isEmpty {
            // Те же размер и шаг, что у «Избранного»: плитка 29 + кольцо 3×2
            // Закреплённые — кружками-сотами
            HoneycombLayout(diameter: IconTile.size + 6, gap: 6) {
                ForEach(sp.pinned) { PinnedCell(tab: $0) }
            }
            // Пока тащишь вкладку — область облегает значки с местом под ещё один (по ширине ряда панели)
            // (не шире панели — иначе список съезжает, см. Metrics.sidebarContentWidth)
            .frame(minWidth: min(CGFloat(min(sp.pinned.count + 1, 5)) * (IconTile.size + 12) - 6, Metrics.sidebarContentWidth))
            .background { PinZoneHint(space: sp) }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .reportFrame { model.drag.pinnedZone = $0 }   // бросать можно по всей ширине ряда
        } else if PinZoneHint.showsPlaceholder(model) {
            // Закреплённых нет: пока тащишь вкладку, на их месте — область «закрепить»
            PinDropPlaceholder(round: false)
                .reportFrame { model.drag.pillZone = $0 }
        }

        // Инкогнито без прокси VPN — ходит напрямую: заметно предупреждаем, включается одной кнопкой
        if sp.isIncognito { IncognitoDirectNotice() }

        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 2) {
                // Инкогнито ничего не хранит — плоский список (сохранённого там нет), сверху «стереть всё»
                if sp.isIncognito { EraseIncognitoLine(space: sp) }
                // Сверху сохранённое — папки (под раскрытыми их вкладки с отступом),
                // под разделителем — временные вкладки, они уходят в архив
                if !sp.savedEntries.isEmpty { SavedHeader(space: sp) }
                if sp.savedCollapsed {
                    // Свёрнуто: видна только открытая сейчас вкладка из сохранённого (как у свёрнутой папки)
                    if let t = model.activeTab, !t.isPinned, sp.tabs.contains(where: { $0 === t }),
                       !sp.isTemp(t) {
                        TabRow(tab: t)
                    }
                } else {
                    ForEach(sp.savedEntries) { e in
                        switch e {
                        case .folder(let f): FolderBlock(folder: f, space: sp)
                        case .tab(let t): TabWithBranches(tab: t, space: sp, indent: 0)
                        }
                    }
                }
                if !sp.entries.isEmpty && !sp.isIncognito {
                    TempDivider(space: sp, showLine: !sp.savedEntries.isEmpty)
                        .reportFrame { model.drag.dividerFrame = $0 }
                }
                if sp.tempCollapsed {
                    // Свёрнуто: видна только открытая сейчас временная вкладка
                    if let t = model.activeTab, !t.isPinned, sp.tabs.contains(where: { $0 === t }), sp.isTemp(t) {
                        TabRow(tab: t)
                    }
                } else {
                    ForEach(sp.tempEntries) { e in
                        switch e {
                        case .folder(let f): FolderBlock(folder: f, space: sp)
                        case .tab(let t): TabRow(tab: t)
                        }
                    }
                }
            }
            // Запас внутри прокрутки: подложка папки выходит за строки на 4 — прокрутка её не обрезает
            .padding(4)
        }
        // Список прокручивается только по вертикали — вбок не пружинит (иначе дёргается при свайпе пространств)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // «Reveal Tab in Sidebar»: сначала к строке верхнего уровня (папке), когда раскроется — к самой вкладке
        .onChange(of: model.revealTick) {
            let ids = model.revealIDs
            guard sp === model.currentSpace, let first = ids.first else { return }
            withAnimation(.easeInOut(duration: model.revealCenter ? 0.3 : 0.15)) { proxy.scrollTo(first, anchor: model.revealCenter ? .center : nil) }
            if let last = ids.last, last != first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .center) }
                }
            }
        }
        }
        .padding(-4)
        .reportFrame { model.drag.listZone = $0 }
        // Инкогнито заперто — названия вкладок не видны и не нажимаются
        .opacity(sp.isIncognito && IncognitoLock.shared.locked ? 0 : 1)
        .allowsHitTesting(!(sp.isIncognito && IncognitoLock.shared.locked))
        .accessibilityHidden(sp.isIncognito && IncognitoLock.shared.locked)
        // Открылась вкладка (из поиска, ⌃Tab, ссылкой, в папке) за краем списка — довести список до неё
        .onChange(of: model.activeTab?.id) { _, id in
            guard sp === model.currentSpace, let id, let t = model.activeTab, !t.isPinned else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard model.activeTab?.id == id else { return }
                let zone = model.drag.listZone
                if let f = model.drag.rowFrames[id], zone.height > 0,
                   f.minY >= zone.minY - 1, f.maxY <= zone.maxY + 1 { return }      // и так видна
                // Строки вне экрана ещё не созданы — сначала к строке верхнего уровня (папке), потом к самой вкладке
                var entry = id
                var f = sp.folders.first { $0.id == t.folderID }
                while let cur = f { entry = cur.id; f = sp.parent(of: cur) }
                model.revealIDs = [entry, id]
                model.revealCenter = false
                model.revealTick += 1
            }
        }
        .contextMenu { if !sp.isIncognito { Button("New Folder…") { model.newFolder() } } }
    }
    }
}

/// Плавающая капсула сверху: панель, назад/вперёд, обновить, адрес (клик — правка), скопировать ссылку.
struct TopBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        // Те же кнопки и адрес, что в полосе над страницей (порядок общий, меняется перетаскиванием), «⋯» — справа
        HStack(spacing: 2) {
            if !model.sidebarVisible {
                ToolbarButton(icon: "sidebar.left", help: "Show sidebar — \(Shortcuts.shared.text(.sidebar))") { model.sidebarVisible = true }
            }
            BarRow(capsule: true, dark: false)
            PageMenu()
        }
        .padding(.horizontal, 5)
        .frame(height: 38)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .onHover { model.topBarHover($0) }
    }
}

/// Свёрнутая капсула: полоска у верхней кромки посередине; наведёшь — раскрывается.
/// Она же показывает загрузку (LoaderStrip): делится на отрезки у краёв, они растут к центру,
/// сходятся в кружок и с отскоком снова растягиваются в полоску.
struct TopBarHandle: View {
    @Environment(BrowserModel.self) private var model
    var body: some View {
        let t = model.activeTab
        LoaderStrip(tab: t, handle: true)
            .frame(width: 120, height: 12)
            // Тень чуть-чуть и чёткая — полоска не мылится
            .shadow(color: .black.opacity(0.18), radius: 0.6, y: 0.5)
            .padding(.top, -3)
            // Наводить удобно: область шире самой полоски
            .frame(width: 200, height: 22, alignment: .top)
            .contentShape(Rectangle())
            .onHover { if $0 { model.showTopBar() } }
            .onTapGesture { model.showTopBar() }
            .help(t?.url?.host ?? "")
    }
}

/// Полоска загрузки. Пока грузится — два отрезка стоят крайними концами на месте и удлиняются к центру
/// (до 99%). Сошлись — крайние концы резко подтягиваются, получается кружок с отскоком; дальше он либо
/// растягивается в полоску спрятанного адреса (`handle`), либо исчезает (адрес виден).
struct LoaderStrip: View {
    let tab: Tab?
    let handle: Bool

    static let stripW: CGFloat = 80, stripH: CGFloat = 6
    static let dot: CGFloat = 9
    /// Где стоят крайние концы отрезков (от центра)
    private var edge: CGFloat { handle ? Self.stripW / 2 : 58 }
    private var thick: CGFloat { handle ? Self.stripH : 3.5 }
    private static let start: CGFloat = 7           // длина отрезков в начале

    private enum Phase { case idle, loading, dot }
    @State private var phase: Phase = .idle
    @State private var inner: CGFloat = 0           // кончики — от центра
    @State private var outer: CGFloat = 40          // крайние концы — от центра
    @State private var h: CGFloat = 6
    @State private var size: CGFloat = LoaderStrip.stripW   // одна фигура: полоска или кружок
    @State private var tint = 0.0
    @State private var scale: CGFloat = 1
    @State private var visible = 1.0
    @State private var run = 0

    var body: some View {
        let loading = tab?.isLoading ?? false
        ZStack {
            switch phase {
            case .loading:
                piece(-1); piece(1)
            case .dot, .idle:
                if handle || phase == .dot {
                    shape.frame(width: size, height: phase == .dot && size <= Self.dot + 0.5 ? size : (handle ? h : size))
                }
            }
        }
        .scaleEffect(scale)
        .opacity(visible)
        .onAppear { reset(loading: loading, progress: tab?.progress ?? 0) }
        .onChange(of: loading) { _, now in if now { begin() } else { finish() } }
        .onChange(of: tab?.progress ?? 0) { _, p in if loading { glide(p) } }
        .onChange(of: tab?.id) { reset(loading: tab?.isLoading ?? false, progress: tab?.progress ?? 0) }
    }

    /// Полоска спрятанного адреса — «стекло» с обводкой; пока грузится — в цвет акцента
    private var shape: some View {
        Capsule()
            .fill(handle ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(Color.accentColor))
            .overlay(Capsule().fill(Color.accentColor).opacity(handle ? tint : 0))
            .overlay(Capsule().strokeBorder(Color.black.opacity(handle ? 0.22 : 0), lineWidth: 0.5))
    }

    private func piece(_ side: CGFloat) -> some View {
        let len = max(h, outer - inner)
        return shape.frame(width: len, height: h).offset(x: side * (inner + len / 2))
    }

    private func still(_ f: () -> Void) {
        var tr = Transaction(); tr.disablesAnimations = true
        withTransaction(tr, f)
    }

    /// Другая вкладка или появились — сразу её состояние, без анимации
    private func reset(loading: Bool, progress: Double) {
        run += 1
        still {
            scale = 1; visible = 1
            if loading {
                phase = .loading; tint = 1; h = thick; outer = edge
                inner = (edge - Self.start) * (1 - target(progress))
            } else {
                phase = .idle; tint = 0; h = Self.stripH; size = Self.stripW
                visible = handle ? 1 : 0
            }
        }
    }

    /// Доля пути кончиков к центру: до 99% загрузки — чуть не сходятся
    private func target(_ p: Double) -> CGFloat { CGFloat(min(0.97, max(0, p / 0.99))) }

    private func begin() {
        run += 1
        if handle {
            // Полоска распадается: середина уходит, у краёв остаются короткие отрезки
            still { phase = .loading; inner = 0; outer = edge; h = Self.stripH; visible = 1; scale = 1 }
            withAnimation(.easeOut(duration: 0.25)) { inner = edge - Self.start; tint = 1 }
        } else {
            still { phase = .loading; inner = edge - Self.start; outer = edge; h = thick; tint = 1; scale = 1; visible = 0 }
            withAnimation(.easeOut(duration: 0.2)) { visible = 1 }
        }
        glide(tab?.progress ?? 0)
    }

    /// Кончики тянутся к центру, крайние концы стоят на месте
    private func glide(_ p: Double) {
        guard phase == .loading else { return }
        let to = (edge - Self.start) * (1 - target(p))
        guard to < inner - 0.3 else { return }
        withAnimation(.easeOut(duration: 0.5)) { inner = to }
    }

    private func finish() {
        guard phase == .loading else { return }
        run += 1
        let r = run
        // Сошлись в центре…
        withAnimation(.easeIn(duration: 0.1)) { inner = 0 }
        // …и крайние концы резко подтягиваются: кружок
        withAnimation(.easeIn(duration: 0.13).delay(0.1)) { outer = Self.dot / 2; inner = -Self.dot / 2; h = Self.dot }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard r == run else { return }
            still { phase = .dot; size = Self.dot; scale = 1.35 }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { scale = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard r == run else { return }
                if handle {
                    // Растягивается в полоску спрятанного адреса, цвет уходит
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { size = Self.stripW; h = Self.stripH }
                    withAnimation(.easeOut(duration: 0.45).delay(0.1)) { tint = 0 }
                    phase = .idle
                } else {
                    // Адрес виден — кружок просто исчезает
                    withAnimation(.easeIn(duration: 0.2)) { scale = 0.2; visible = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { if r == run { still { phase = .idle } } }
                }
            }
        }
    }
}

struct NavButton: View {
    let icon: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 20)
                .background(hover && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .circular))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Пока тащишь вкладку, область закреплённых обведена пунктиром; наведёшь на неё — подсвечивается.
struct PinZoneHint: View {
    let space: Space
    var round = false
    @Environment(BrowserModel.self) private var model
    private var drag: TabDrag { model.drag }
    /// Тащат вкладки (не папку)
    static func showsPlaceholder(_ m: BrowserModel) -> Bool { m.drag.active && m.drag.folderDrag == nil }
    var body: some View {
        if drag.active, drag.folderDrag == nil {
            let on: Bool = { if case .pinned = drag.target { return true }; return false }()
            let shape = RoundedRectangle(cornerRadius: round ? 22 : 18, style: .circular)
            GeometryReader { g in
                let w = g.size.width + (round ? 6 : 20)
                shape.fill(space.tint.opacity(on ? 0.22 : 0.08))
                    .overlay(shape.strokeBorder(space.dropLine.opacity(on ? 1 : 0.45), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                    // По высоте — в пределах полей ряда (2 сверху и снизу): иначе верх обрезается краем списка
                    .frame(width: w, height: g.size.height + 4)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
                .animation(.easeOut(duration: 0.12), value: on)
                .allowsHitTesting(false)
        }
    }
}

/// Место под закреплённые, когда их ещё нет: видно только во время перетаскивания вкладки
struct PinDropPlaceholder: View {
    @Environment(BrowserModel.self) private var model
    let round: Bool
    private var drag: TabDrag { model.drag }
    var body: some View {
        let sp = model.currentSpace
        let on: Bool = { if case .pinned = drag.target { return true }; return false }()
        let shape = RoundedRectangle(cornerRadius: round ? 16 : 18, style: .circular)
        ZStack {
            shape.fill(sp.tint.opacity(on ? 0.22 : 0.08))
            shape.strokeBorder(sp.dropLine.opacity(on ? 1 : 0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            if round {
                Image(systemName: "pin").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                Label("Drop here to pin", systemImage: "pin").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(width: round ? CompactSidebar.cell : nil, height: round ? CompactSidebar.cell : 36)
        .frame(maxWidth: round ? nil : .infinity)
        .animation(.easeOut(duration: 0.12), value: on)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

/// Кружок «обновить» в конце адресной строки; наведёшь — слева выезжают «назад» и «вперёд».
struct NavCluster: View {
    @Environment(BrowserModel.self) private var model
    @State private var hover = false

    var body: some View {
        let t = model.activeTab
        HStack(spacing: 2) {
            if hover {
                NavCircle(icon: "chevron.left", enabled: t?.canGoBack ?? false) { PageSwipe.shared.step(t?.webView, back: true) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                NavCircle(icon: "chevron.right", enabled: t?.canGoForward ?? false) { PageSwipe.shared.step(t?.webView, back: false) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            NavCircle(icon: t?.isLoading == true ? "xmark" : "arrow.clockwise", filled: true) {
                if t?.isLoading == true { t?.webView?.stopLoading() } else { t?.reload() }
            }
            .help(t?.isLoading == true ? "Stop — ⌘." : "Reload — ⌘R")
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hover = h } }
    }
}

private struct NavCircle: View {
    let icon: String
    var enabled = true
    var filled = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hover && enabled ? 0.14 : filled ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Профиль текущего пространства в верхнем ряду панели. Клик — профили с их пространствами (прыгнуть),
/// смена профиля у этого пространства, новый профиль.
struct SpaceNameChip: View {
    @Environment(BrowserModel.self) private var model
    var body: some View {
        let sp = model.currentSpace
        let p = sp.profile
        Menu {
            ForEach(model.profiles) { pr in
                let own = model.spaces.enumerated().filter { $0.element.profileID == pr.id && !$0.element.isIncognito }
                Section(pr.name) {
                    ForEach(own, id: \.element.id) { i, s in
                        Button((s.id == sp.id ? "✓ " : "    ") + s.name) { model.swipe.switchTo(i, model: model) }
                    }
                }
            }
            Divider()
            if !sp.isIncognito {
                Menu("Profile for “\(sp.name)”") {
                    ForEach(model.profiles) { pr in
                        Button((pr.id == sp.profileID ? "✓ " : "    ") + pr.name) { model.setProfile(sp, pr) }
                    }
                    Divider()
                    Button("New Profile…") { model.newProfile(for: sp) }
                }
            }
            Button("New Profile…") { model.newProfile() }
            Button("Rename “\(p.name)”…") { model.renameProfile(p) }
            if !p.isPrimary { Button("Delete “\(p.name)”…") { model.deleteProfile(p) } }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(sp.isIncognito ? Color.purple : p.color).frame(width: 8, height: 8)
                Text(sp.isIncognito ? "Incognito" : p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile of this space — its own sign-ins")
    }
}

struct AddressPill: View {
    @Environment(BrowserModel.self) private var model
    @State private var siteCenter = false
    @AppStorage(Prefs.fullAddress) private var fullAddress = false

    var body: some View {
        let url = model.activeTab?.url
        HStack(spacing: 6) {
            // Замок / щит — центр сайта: приватность, настройки страницы, разрешения
            if let t = model.activeTab, url?.host != nil {
                Button { siteCenter.toggle() } label: {
                    HStack(spacing: 3) {
                        // Шестерёнка — настройки сайта; незащищённое соединение — оранжевая
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(url?.scheme == "https" ? Color.secondary : Color.orange)
                    .frame(minWidth: 18, minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Site settings and privacy")
                .popover(isPresented: $siteCenter, arrowEdge: .top) { SiteCenter(tab: t).environment(model).windowScheme() }
            }
            Text(url.map { fullAddress ? $0.absoluteString : shortURL($0) } ?? "Search or enter address")
                .font(.system(size: 13))
                .foregroundStyle(url == nil ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)   // конец хоста виден: paypal.com.evil.io не спрячется за «…»
            Spacer(minLength: 0)
            if let t = model.activeTab, t.translated {
                Button { PageTranslator.shared.toggle(t) } label: {
                    Image(systemName: "translate").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Translated — click to show the original")
            }
            if Ext.active { ExtensionsMenuButton() }
            NavCluster()
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(sidebarShade(Metrics.blockShade * 1.4), in: Capsule())
        .contentShape(Rectangle())
        .onTapGesture { model.showCommandBar(.current) }
        .help("⌘L")
        .contextMenu {
            Button("Show Toolbar Above the Page") { PageToolbar.toggle() }
        }
    }

    private func shortURL(_ u: URL) -> String {
        var host = u.host ?? u.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = u.path == "/" ? "" : u.path
        return host + path
    }
}

struct TabRow: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    /// Отступ содержимого (вкладка в папке, веточка): сдвигается фавикон с названием,
    /// а подсветка строки — на всю ширину, концентрично подложке папки
    var indent: CGFloat = 0
    @State private var hover = false
    @State private var rowID = UUID()
    @State private var globalFrame: CGRect = .zero
    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    @Environment(\.rowCorner) private var rowCorner

    var body: some View {
        let sp = model.currentSpace
        // Вкладка в сплите: всю группу рисует одна строка (на месте первой из её вкладок в списке)
        if !tab.isPinned, let g = sp.group(of: tab.id), let lead = sp.splitLead(of: tab) {
            if lead === tab { SplitRow(lead: tab, group: g, indent: indent) }
        } else {
            row
        }
    }

    @ViewBuilder private var row: some View {
        let sp = model.currentSpace
        let visible = model.isVisible(tab)
        // Floating: активная вкладка — вырез в карточке цвета сайта (кроме вкладок в папках и пока цвет неизвестен)
        let isFloating = model.sidebarVisible && sidebarStyle == "floating"
        let growing = model.activeRow.growID == tab.id
        let onNotch = isFloating && model.activeTab === tab && tab.pageColor != nil && !growing
        let floatingFill = isFloating && !onNotch
        let sel = model.selection
        let selected = sel.contains(tab)
        // Соседи по выделению — чтобы группа рисовалась одной общей рамкой
        let list = sp.visual
        let i = list.firstIndex { $0.id == tab.id } ?? 0
        let prevSel = selected && i > 0 && sel.contains(list[i - 1])
        let nextSel = selected && i + 1 < list.count && sel.contains(list[i + 1])
        let dragging = model.drag.ids.contains(tab.id) && model.drag.active
        let showClose = hover && !model.drag.active
        let kids = tab.isBranch ? 0 : sp.branches(of: tab).count
        let sound = tab.audible || tab.muted
        // Вырез красится краем страницы на высоте строки (видео, тёмная картинка), а не общим цветом сайта —
        // подпись и значки берут тот же цвет, иначе тёмное на тёмном
        let notchDark = isDark(tab.edgeStrip.flatMap { s in model.activeRow.tabID == tab.id ? s.color(atY: model.activeRow.frame.midY) : nil } ?? tab.pageColor)
        // ✕ и стрелка — в цвет подписи: на вырезе цвета сайта (часто тёмном) серый не виден
        let accessory: AnyShapeStyle = onNotch
            ? AnyShapeStyle(notchDark ? Color.white.opacity(0.75) : Color.black.opacity(0.55))
            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
        HStack(spacing: 8) {
            // Открыта под другим профилем (или во временном контейнере) — значок профиля слева от значка сайта
            if tab.temporary || tab.profileOverride != nil { ProfileBadge(tab: tab, large: true).padding(.trailing, -3) }
            Favicon(url: tab.url)
                .frame(width: 16, height: 16)
                .opacity(tab.asleep && !visible ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    if BrowserModel.archiveAfter > 0, BrowserModel.archivable(tab, in: sp) {
                        ArchiveDot { BrowserModel.archiveLeft(tab, in: sp, now: $0) }
                    }
                }
            // Название всегда на всю ширину: крестик при наведении ложится поверх его конца (текст там гаснет),
            // а не сжимает его — иначе при наведении и правом клике название перестраивается и «дёргается»
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(onNotch ? AnyShapeStyle(notchDark ? Color.white : Color.black.opacity(0.85))
                                 : tab.asleep && !visible ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        if showClose || kids > 0 || sound {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                            Color.clear.frame(width: (showClose ? 18 : 0) + (sound ? 20 : 0) + (kids > 0 ? (tab.branchesExpanded ? 14 : 22) : 0))
                        }
                    }
                }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                // Звук: играет — динамик, выключен — перечёркнутый; клик — выключить / включить
                if sound {
                    Button { tab.muted.toggle() } label: {
                        Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accessory)
                    .help(tab.muted ? "Unmute tab" : "Mute tab")
                }
                if showClose {
                    RowCloseButton(tab: tab, saved: !sp.isTemp(tab) && !tab.isPinned, style: accessory)
                }
                // Под вкладкой есть веточки: › — свёрнуты, ⌄ — раскрыты
                if kids > 0 {
                    Button {
                        ListMotion.animate { tab.branchesExpanded.toggle() }
                    } label: {
                        HStack(spacing: 2) {
                            if !tab.branchesExpanded { Text("\(kids)").font(.system(size: 10).monospacedDigit()) }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(tab.branchesExpanded ? 90 : 0))
                        }
                        .frame(minWidth: 18, minHeight: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accessory)
                    .help(tab.branchesExpanded ? "Collapse linked tabs" : "Show linked tabs")
                }
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background {
            // Внутри выделения подсветка активной вкладки повторяет форму общей рамки — без своих уголков
            Group {
                if model.drag.hoverTab == tab.id {
                    DropHint(space: sp)            // бросишь — откроются сплитом с этой вкладкой
                } else if selected {
                    SelectionSegment(space: sp, top: !prevSel, bottom: !nextSel, gapBelow: nextSel ? 2 : 0, active: visible)
                } else if visible && !growing && !(model.sidebarVisible && model.activeTab === tab && !floatingFill) {
                    ActiveFill(space: sp)
                } else if hover && !visible {
                    RoundedRectangle(cornerRadius: rowCorner, style: .circular).fill(sidebarShade(0.05))
                }
            }
            // Вне папок подсветка — в ширину блока папки (он выступает за строки на 4)
            .padding(.horizontal, tab.folderID == nil ? -4 : 0)
        }
        .opacity(dragging ? 0.35 : 1)
        .id(tab.id)                          // «Reveal Tab in Sidebar» прокручивает к строке
        .contentShape(Rectangle())
        .onTapGesture { model.selection.click(tab, model: model) }
        .tabDrag(tab, model: model)
        .reportFrame { f in
            model.drag.rowFrames[tab.id] = f
            if model.activeTab === tab { model.activeRow.set(tab.id, f, compact: false, owner: rowID) }
        }
        .onChange(of: model.activeTab === tab) { _, isActive in
            if isActive, let f = model.drag.rowFrames[tab.id] { model.activeRow.set(tab.id, f, compact: false, owner: rowID) }
            else if !isActive { model.activeRow.clear(tab.id, compact: false, owner: rowID) }
        }
        .onDisappear { model.activeRow.clear(tab.id, compact: false, owner: rowID); model.hoverPreview.hover(tab, frame: .zero, on: false, model: model) }
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear.onAppear { globalFrame = f }.onChange(of: f) { globalFrame = f }
        })
        .onHover { h in
            hover = h
            model.hoverPreview.hover(tab, frame: globalFrame, on: h, model: model)
        }
        .simultaneousGesture(TapGesture().onEnded { model.hoverPreview.hide() })
        .contextMenu {
            if selected && model.selection.ids.count > 1 { GroupMenu() } else { TabMenu(tab: tab) }
        }
    }
}

// MARK: - Избранное: круглые значки сотами

/// Соты: полные ряды чередуются с рядами на один короче, сдвинутыми на полшага.
struct HoneycombLayout: Layout {
    var diameter: CGFloat
    var gap: CGFloat

    private func perRow(_ width: CGFloat) -> Int { max(2, Int((width + gap) / (diameter + gap))) }
    private var rowStep: CGFloat { (diameter + gap) * 0.866 }   // sin 60°

    /// Разбивка на ряды: 4, 3, 4, 3…
    private func rows(_ count: Int, width: CGFloat) -> [Int] {
        let n = perRow(width)
        var left = count, r: [Int] = [], full = true
        while left > 0 { let k = min(left, full ? n : n - 1); r.append(k); left -= k; full.toggle() }
        return r
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? (diameter + gap) * 4
        let rs = rows(subviews.count, width: w)
        // Ширина — по самому длинному ряду значков (а не вся панель): подсветка области облегает значки
        let k = rs.max() ?? 0
        let used = k == 0 ? 0 : CGFloat(k) * diameter + CGFloat(k - 1) * gap
        return CGSize(width: min(w, used), height: rs.isEmpty ? 0 : diameter + CGFloat(rs.count - 1) * rowStep)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Каждый ряд — по центру панели; ряды на один короче сами встают со сдвигом на полшага
        var i = 0
        for (ri, k) in rows(subviews.count, width: bounds.width).enumerated() {
            let rowWidth = CGFloat(k) * diameter + CGFloat(k - 1) * gap
            let x0 = bounds.minX + (bounds.width - rowWidth) / 2
            for c in 0..<k {
                let x = x0 + CGFloat(c) * (diameter + gap)
                let y = bounds.minY + CGFloat(ri) * rowStep
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: diameter, height: diameter))
                i += 1
            }
        }
    }
}

/// Значок сайта в плитке: «во весь квадрат» — на всю площадь, значок с полями — в центр на ровный фон.
/// Кружок для «Избранного», скруглённый квадрат для закреплённых — одного размера.
struct IconTile: View {
    static let size: CGFloat = 29
    let tab: Tab
    var d: CGFloat = IconTile.size
    var round = true
    let visible: Bool
    let selected: Bool
    let space: Space

    var body: some View {
        let shape = AnyShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .circular)))
        let ring = AnyShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8 + 3, style: .circular)))
        let host = tab.url?.host
        let img = host.flatMap { FaviconStore.shared.image(for: $0) }
        let full = host.flatMap { FaviconStore.shared.fullBleed[$0] } ?? false
        ZStack {
            shape.fill(Color(nsColor: .controlBackgroundColor))
            if let img, full {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
            } else if let img {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                    .frame(width: d * 0.56, height: d * 0.56)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                    .frame(width: d * 0.5, height: d * 0.5)
            }
        }
        .frame(width: d, height: d)
        .clipShape(shape)
        // Чёткий контур и тень — значки не теряются на светлой панели; спящие лишь чуть приглушены
        .overlay(shape.stroke(Color.black.opacity(0.14), lineWidth: 0.5))
        // Открытая — не кольцом, а мягкой тенью: значок чуть «приподнят» над панелью
        .shadow(color: .black.opacity(visible && !selected ? 0.37 : 0.185), radius: visible && !selected ? 5 : 2, y: visible && !selected ? 2.5 : 1)
        .saturation(tab.asleep && !visible ? 0.9 : 1)
        .opacity(tab.asleep && !visible ? 0.92 : 1)
        // Выделенная — кольцо и подкраска (открытая — тенью выше)
        .padding(3)
        .overlay {
            if selected {
                ring.stroke(space.tintStrong.opacity(0.85), lineWidth: 2).padding(1)
                    .background(ring.fill(space.tint.opacity(0.18)))
            }
        }
        .overlay(alignment: .bottomTrailing) { SoundBadge(tab: tab) }
    }
}

/// Значок звука на круглом значке вкладки (закреплённые, узкая колонка); клик — выключить / включить звук
struct SoundBadge: View {
    let tab: Tab
    var body: some View {
        if tab.audible || tab.muted {
            Button { tab.muted.toggle() } label: {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Color.black.opacity(0.6), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(tab.muted ? "Unmute tab" : "Mute tab")
        }
    }
}

struct FavoriteCell: View {
    static let diameter: CGFloat = IconTile.size
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    @State private var hover = false

    var body: some View {
        let selected = model.selection.contains(tab)
        let dragging = model.drag.ids.contains(tab.id) && model.drag.active
        // В узкой колонке — по сетке 32 pt (26 + кольцо)
        IconTile(tab: tab, d: Metrics.compact ? CompactSidebar.cell - 6 : IconTile.size, round: true,
                 visible: model.isVisible(tab), selected: selected, space: model.currentSpace)
            .scaleEffect(hover && !model.drag.active ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .opacity(dragging ? 0.35 : 1)
            .contentShape(Circle())
            .onTapGesture { model.selection.click(tab, model: model) }
            .tabDrag(tab, model: model)
            .reportFrame { model.drag.favFrames[tab.id] = $0 }
            .onHover { hover = $0 }
            .contextMenu {
                if selected && model.selection.ids.count > 1 { GroupMenu() } else { TabMenu(tab: tab) }
            }
            .help(tab.displayTitle)
    }
}

struct PinnedCell: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    @State private var hover = false

    var body: some View {
        let selected = model.selection.contains(tab)
        let dragging = model.drag.ids.contains(tab.id) && model.drag.active
        IconTile(tab: tab, round: true, visible: model.isVisible(tab), selected: selected, space: model.currentSpace)
            .scaleEffect(hover && !model.drag.active ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .opacity(dragging ? 0.35 : 1)
            // Клик по открытому, ушедшему со своего адреса, — вернуться на адрес закрепления
            .contentShape(Rectangle())
            .onTapGesture {
                if model.activeTab === tab, tab.awayFromPin, !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) {
                    tab.backToPin()
                } else {
                    model.selection.click(tab, model: model)
                }
            }
            .tabDrag(tab, model: model)
            .reportFrame { model.drag.pinnedFrames[tab.id] = $0 }
            .onHover { hover = $0 }
            .contextMenu {
                if selected && model.selection.ids.count > 1 { GroupMenu() } else { TabMenu(tab: tab) }
            }
            .help(tab.displayTitle)
    }
}

/// Ровная сетка плиток одного размера, ряды по центру (как соты «Избранного», только без сдвига).
struct TileGrid: Layout {
    var size: CGFloat
    var gap: CGFloat
    private func perRow(_ w: CGFloat) -> Int { max(1, Int((w + gap) / (size + gap))) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? (size + gap) * 6
        let rows = (subviews.count + perRow(w) - 1) / perRow(w)
        return CGSize(width: w, height: rows == 0 ? 0 : CGFloat(rows) * size + CGFloat(rows - 1) * gap)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = perRow(b.width)
        let rowW = CGFloat(n) * size + CGFloat(n - 1) * gap
        let x0 = b.minX + (b.width - rowW) / 2
        for (i, v) in subviews.enumerated() {
            let x = x0 + CGFloat(i % n) * (size + gap)
            let y = b.minY + CGFloat(i / n) * (size + gap)
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size, height: size))
        }
    }
}

/// Маска подложки папки: сплошная, кроме места под вырезом активной вкладки (Floating и узкая закреплённая колонка)
struct FolderNotchMask: View {
    @Environment(BrowserModel.self) private var model
    let folder: Folder
    @AppStorage("sidebarStyle") private var sidebarStyle = "attached"
    var body: some View {
        GeometryReader { g in
            let o = g.frame(in: .named(TabDrag.space)).origin
            let row = model.activeRow
            let t = model.activeTab
            let sp = model.currentSpace
            let tf = t?.folderID.flatMap { id in sp.folders.first { $0.id == id } }
            let notch = model.sidebarVisible && t?.pageColor != nil && sp.isInside(tf, folder) && row.tabID == t?.id
                && (sidebarStyle == "floating" || Metrics.compact)
            ZStack(alignment: .topLeading) {
                Rectangle()
                if notch {
                    let f = row.frame
                    // Полукруглый край чуть левее строки (как у выреза), вправо — до края панели
                    Capsule()
                        .frame(width: f.width + 60, height: f.height)
                        .offset(x: f.minX - o.x - (Metrics.compact ? 3 : 0), y: f.minY - o.y)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
    }
}

/// Сохранённая вкладка и её веточки (ссылки, открытые из неё). Веточки с красной точкой уйдут в архив.
struct TabWithBranches: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    let space: Space
    let indent: CGFloat
    var body: some View {
        TabRow(tab: tab, indent: indent)
        if tab.branchesExpanded {
            ForEach(space.branches(of: tab)) { b in
                TabRow(tab: b, indent: indent + 16)
            }
        }
    }
}

/// Разделитель между сохранённым (папки) и временными вкладками; «Clear» закрывает временные в архив (⇧⌘K)
/// Стрелка свернуть / развернуть — справа; свёрнуто — рядом число скрытого
struct FoldButton: View {
    let collapsed: Bool
    let count: Int
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if collapsed {
                    Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 90 : 0))
            }
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.primary.opacity(hover ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Верх сохранённого — как линия «Temp»: черта — «Pinned» посередине — стрелка свернуть справа
struct SavedHeader: View {
    @Environment(BrowserModel.self) private var model
    let space: Space
    @State private var hover = false
    var body: some View {
        let toggle = { ListMotion.animate { space.savedCollapsed.toggle() }; model.save() }
        SectionLine(fold: true) {
            Button(action: toggle) {
                Text("Pinned").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(hover ? .primary : .secondary)
                    .frame(width: sectionLabelWidth, height: 20)
                    .background(Color.primary.opacity(hover ? 0.1 : 0.05), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(space.savedCollapsed ? "Show saved tabs and folders" : "Collapse saved tabs and folders")
        } trailing: {
            FoldButton(collapsed: space.savedCollapsed, count: space.savedEntries.count,
                       help: space.savedCollapsed ? "Show saved tabs and folders" : "Collapse saved tabs and folders",
                       action: toggle)
        }
        .contextMenu {
            Button(space.savedCollapsed ? "Show Saved Tabs" : "Collapse Saved Tabs", action: toggle)
        }
    }
}

/// Линия раздела: черты, подпись ровно посередине, справа — стрелка (её ширина меняется, центр не сдвигает)
/// Ширина подписи на линии раздела («Pinned», «Temp» / «Clear»)
let sectionLabelWidth: CGFloat = 66

struct SectionLine<Label: View, Trailing: View>: View {
    var fold: Bool
    /// Ширина подписи (черты начинаются от неё с отступом)
    var labelWidth: CGFloat = sectionLabelWidth
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.22)).frame(height: 1.5)
                Color.clear.frame(width: labelWidth, height: 1)
                // Со стрелкой правой черты нет: от неё оставался обрубок у стрелки. Место то же — подпись посередине
                Capsule().fill(Color.primary.opacity(fold ? 0 : 0.22)).frame(height: 1.5)
            }
            label
            if fold { trailing.frame(maxWidth: .infinity, alignment: .trailing) }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
    }
}

/// Красная точка на значке: временная вкладка уйдёт в архив меньше чем через час
struct ArchiveDot: View {
    /// Сколько осталось до архива на момент времени (nil — не уйдёт)
    let left: (Date) -> TimeInterval?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            if let left = left(ctx.date), left < 3600 {
                Circle().fill(Color.red)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor).opacity(0.9), lineWidth: 1))
                    .offset(x: 2, y: -2)
                    .help("Will be archived in \(max(1, Int(left / 60))) min")
            }
        }
    }
}

struct TempDivider: View {
    @Environment(BrowserModel.self) private var model
    var space: Space? = nil
    var showLine = true
    @State private var hover = false
    /// Задержался курсор на «Temp» — надпись становится красной «Clear», клик очищает временные
    @State private var armed = false
    @State private var armWork: DispatchWorkItem?
    var body: some View {
        // Черта — «Temp» (клик — свернуть; подержал курсор — красная «Clear») — черта — стрелка свернуть
        let fold = space.map { !$0.tempEntries.isEmpty } ?? false
        let toggle = {
            guard let sp = space, !sp.tempEntries.isEmpty else { return }
            ListMotion.animate { sp.tempCollapsed.toggle() }; model.save()
        }
        SectionLine(fold: fold) {
            Button {
                if armed { disarm(); model.clearUnpinned() } else { toggle(); arm() }   // свернул/развернул — отсчёт заново
            } label: {
                HStack(spacing: 4) {
                    if armed { Image(systemName: "arrow.down.to.line").font(.system(size: 9, weight: .bold)) }
                    Text(armed ? "Clear" : "Temp").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(armed ? AnyShapeStyle(Color.white) : hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: sectionLabelWidth, height: 20)
                .background(armed ? Color.red.opacity(0.85) : Color.primary.opacity(hover ? 0.1 : 0.05), in: Capsule())
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.18), value: armed)
            }
            .buttonStyle(.plain)
            .onHover { on in
                hover = on
                if on { arm() } else { disarm() }
            }
            .help(armed ? "Archive temporary tabs — ⇧⌘K" : "Collapse temporary tabs · hold the pointer to clear")
        } trailing: {
            if let sp = space {
                FoldButton(collapsed: sp.tempCollapsed, count: sp.tempEntries.count,
                           help: sp.tempCollapsed ? "Show temporary tabs" : "Collapse temporary tabs", action: toggle)
            }
        }
        .contextMenu {
            if let sp = space, !sp.tempEntries.isEmpty {
                Button(sp.tempCollapsed ? "Show Temporary Tabs" : "Collapse Temporary Tabs", action: toggle)
            }
            Button("New Temporary Folder…") { model.newFolder(temp: true) }
            Divider()
            Button("Clear Temporary Tabs") { model.clearUnpinned() }
        }
    }

    private func disarm() { armWork?.cancel(); armWork = nil; armed = false }
    /// Отсчёт до «Clear» — с начала
    private func arm() {
        disarm()
        let w = DispatchWorkItem { armed = true }
        armWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
}

struct TabMenu: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab

    var body: some View {
        if tab.audible || tab.muted {
            Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.muted.toggle() }.shortcut(.mute)
            Divider()
        }
        if tab.isPinned {
            if tab.awayFromPin {
                Button("Back to Pinned Address") { tab.backToPin() }
                Button("Pin This Address Instead") { tab.pinnedURL = tab.url; model.save() }
            }
            Button("Edit Pinned Address…") {
                if let s = promptText("Pinned address", initial: tab.pinnedURL?.absoluteString ?? ""),
                   let u = Omnibox.url(for: s) { tab.pinnedURL = u; model.save() }
            }
            Divider()
        }
        if !model.currentSpace.inPanes(tab.id) {
            Button("Open in Split View") { model.openInSplit(tab) }
        }
        let inIncognito = model.space(of: tab)?.isIncognito ?? false
        if !model.isFavorite(tab) && !inIncognito {
            Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePin(tab) }.shortcut(.pin)
        }
        Button("Duplicate") { model.duplicate([tab]) }.shortcut(.duplicate)
        if Module.autoReload.isOn { AutoReloadMenu(tab: tab) }
        if !model.isFavorite(tab) && !tab.isPinned && !inIncognito { MoveToFolderMenu(tabs: [tab]) }
        Button("Copy Link") {
            if let u = tab.url?.absoluteString {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u, forType: .string)
            }
        }
        .shortcut(.copyLink)
        Button("Share…") { model.share(tab) }.shortcut(.share).disabled(tab.url == nil)
        if !(model.space(of: tab)?.isIncognito ?? true) && !model.isFavorite(tab) {
            Divider()
            OpenAsMenu(title: "Reopen As", current: tab.effectiveProfileID, currentTemporary: tab.temporary) { p, temp in
                model.reopenAs(tab, profile: p, temporary: temp)
            }
            if let site = SiteSettings.site(tab.url) {
                Menu("Always Open \(site) As") {
                    ForEach(model.profiles) { p in
                        Toggle(p.name, isOn: Binding(get: { BrowserModel.profileRules[site] == p.id },
                                                     set: { model.setRule(for: tab.url, profile: $0 ? p.id : nil) }))
                    }
                    if BrowserModel.profileRules[site] != nil {
                        Divider()
                        Button("No Rule") { model.setRule(for: tab.url, profile: nil) }
                    }
                }
            }
        }
        // Между инкогнито и обычными пространствами вкладки не переносятся (входы и история не смешиваются)
        let incog = model.space(of: tab)?.isIncognito ?? false
        let others = model.spaces.filter { $0.id != model.space(of: tab)?.id && $0.isIncognito == incog }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { s in Button { model.move(tab, to: s) } label: { Label(s.name, systemImage: Symbols.open(s.icon)) } }
            }
        }
        if !incog, tab.url?.host != nil {
            Button("Open in Incognito") { model.openInIncognito([tab]) }
        }
        if !tab.asleep && !model.isVisible(tab) {
            Button("Put Tab to Sleep") { tab.sleep() }
        }
        Divider()
        Button("Rename…") { model.renameTab(tab) }
        if Module.tidyTitles.isOn, !tab.title.isEmpty { Button("Tidy Title") { TidyTitles.tidy(tab, model) } }
        if tab.customTitle != nil { Button("Restore Original Title") { model.checkpoint("Restore Title"); tab.customTitle = nil; model.save() } }
        Divider()
        Button("Close") { model.close(tab) }.shortcut(.closeTab)
        if tab.isPinned {
            // ⌘W и «Close» закреплённую только выгружают; убрать совсем — здесь
            Button("Remove from Pinned") { model.removePinned(tab) }
        }
        if !tab.isPinned && tab.folderID == nil && !tab.isSaved && !tab.isBranch && !model.isFavorite(tab) {
            Button("Close Tabs Above") { model.closeTabs(.above, from: tab) }
            Button("Close Tabs Below") { model.closeTabs(.below, from: tab) }
            Button("Close Other Tabs") { model.closeTabs(.others, from: tab) }
        }
    }
}

struct SpaceBar: View {
    @Environment(BrowserModel.self) private var model
    /// Перетаскивание значка: какое пространство тащат, где был его центр в начале и сдвиг под курсором
    @State private var dragID: UUID?
    @State private var dragStartX: CGFloat = 0
    @State private var dragX: CGFloat = 0
    /// Центры мест под значки — снятые в начале перетаскивания (пока значки едут, их рамки ещё старые)
    @State private var slots: [CGFloat] = []

    var body: some View {
        HStack(spacing: 4) {
            // Значки — по центру ширины панели: слева пустое место размером с «+» справа.
            // Узкая панель и много пространств — сначала уходит это место, потом значки сужаются
            // (иначе ряд распирал всю панель и список вкладок съезжал влево)
            Color.clear.frame(minWidth: 0, maxWidth: 26, maxHeight: 1).layoutPriority(-1)
            Spacer(minLength: 0)
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { i, s in
                let current = s.id == model.currentSpaceID
                let dropHere = model.drag.target == .space(s.id)
                // Открыто в другом окне — значок приглушён, клик переводит в то окно
                let elsewhere = BrowserModel.window(showing: s).map { $0 !== model } ?? false
                // Граница профилей: тонкая черта между пространствами разных профилей
                if i > 0, model.spaces[i - 1].profileID != s.profileID || model.spaces[i - 1].isIncognito != s.isIncognito {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 2)
                }
                Button { model.swipe.switchTo(i, model: model) } label: {
                    Image(systemName: current ? Symbols.filled(s.icon) : Symbols.open(s.icon))
                        .font(.system(size: 13))
                        .frame(minWidth: 20, idealWidth: 28, maxWidth: 28)
                        .frame(height: 26)
                        .background(dropHere ? s.tint.opacity(0.5) : current ? Color.primary.opacity(0.1) : .clear,
                                    in: Capsule())
                        .scaleEffect(dropHere ? 1.15 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: dropHere)
                        .opacity(elsewhere ? 0.4 : 1)
                        // Через туннель VPN — маленький щит
                        .overlay(alignment: .bottomTrailing) {
                            if s.isIncognito ? Incognito.proxyOn : Tunnel.isOn(s.profileID) {
                                Image(systemName: "lock.shield.fill").font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.secondary).offset(x: -1, y: -1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .reportFrame { model.drag.spaceFrames[s.id] = $0 }
                .buttonStyle(.plain)
                // Значки можно менять местами — перетаскиванием (инкогнито всегда последнее)
                // Сначала увеличить, потом сдвинуть: иначе увеличивается и сдвиг — значок уезжает дальше курсора
                .scaleEffect(dragID == s.id ? 1.12 : 1)
                .offset(x: dragID == s.id ? dragX : 0)
                .zIndex(dragID == s.id ? 1 : 0)
                .highPriorityGesture(s.isIncognito ? nil : DragGesture(minimumDistance: 4, coordinateSpace: .named(TabDrag.space))
                    .onChanged { v in moveSpace(s, v) }
                    .onEnded { _ in endSpaceDrag() })
                // Попап значка и цвета можно оттянуть или закрепить точкой — останется плавающей панелью
                .background(DetachablePopover(isPresented: Binding(get: { model.spacePicker == s.id }, set: { if !$0 { model.spacePicker = nil } })) {
                    IconColorPicker(icon: Binding(get: { s.icon }, set: { s.icon = $0 }),
                                    hue: Binding(get: { s.hue }, set: { s.hue = $0 }),
                                    sat: Binding(get: { s.sat }, set: { s.sat = $0 }),
                                    bri: Binding(get: { s.bri }, set: { s.bri = $0 }),
                                    willChange: { model.checkpoint("Space Look") },
                                    glow: Binding(get: { s.glow }, set: { s.glow = $0; model.save() }),
                                    glass: Binding(get: { s.glass }, set: { s.glass = $0; model.save() }))
                })
                .foregroundStyle(current ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                .help(elsewhere ? "\(s.name) — open in another window" : i < 9 ? "\(s.name) — \(Shortcuts.shared.text(ShortcutID(rawValue: "space\(i + 1)") ?? .nextSpace))" : s.name)
                .contextMenu {
                  if s.isIncognito {
                    Button("Close Incognito — Erase Everything") { model.closeIncognito(s) }
                  } else {
                    Button("Rename…") { model.rename(s) }
                    // Закреплённые сайты: свои или общие с другим пространством
                    Menu("Pinned Sites") {
                        Button((s.pinnedFrom == nil ? "✓ " : "    ") + "Own") { model.sharePinned(s, from: nil) }
                        let owners = model.spaces.filter { $0 !== s && $0.pinnedFrom == nil && !$0.isIncognito && $0.profileID == s.profileID }
                        if !owners.isEmpty { Divider() }
                        ForEach(owners) { o in
                            Button((s.pinnedFrom == o.id ? "✓ " : "    ") + "Same as “\(o.name)”") { model.sharePinned(s, from: o) }
                        }
                    }
                    // Профиль: чьи входы и куки у этого пространства
                    Menu("Profile") {
                        ForEach(model.profiles) { pr in
                            Button((pr.id == s.profileID ? "✓ " : "    ") + pr.name) { model.setProfile(s, pr) }
                        }
                        Divider()
                        Button("New Profile…") { model.newProfile(for: s) }
                    }
                    Button("Icon & Color…") { model.spacePicker = s.id }
                    if !elsewhere && model.spaces.count > 1 {
                        Button("Open in New Window") { model.openInNewWindow(s) }
                    }
                    if model.spaces.count > 1 {
                        Divider()
                        Button("Delete Space") { model.delete(s) }
                    }
                  }
                }
            }
            Spacer(minLength: 0)
            Button { model.addSpace() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Space")
        }
    }
}

extension SpaceBar {
    /// Тащат значок: встаёт туда, где курсор (между соседями), остальные расступаются
    fileprivate func moveSpace(_ s: Space, _ v: DragGesture.Value) {
        if dragID != s.id {
            let frames = model.drag.spaceFrames
            slots = model.spaces.map { frames[$0.id]?.midX ?? 0 }
            dragStartX = frames[s.id]?.midX ?? v.startLocation.x
            dragID = s.id
            model.checkpoint("Move Space")
        }
        let x = dragStartX + v.translation.width
        var list = model.spaces
        guard let from = list.firstIndex(where: { $0 === s }), slots.count == list.count else { return }
        // Куда: ближайшее место среди обычных пространств (инкогнито — всегда в конце)
        let last = (list.firstIndex { $0.isIncognito } ?? list.count) - 1
        let to = (0...max(0, last)).min { abs(slots[$0] - x) < abs(slots[$1] - x) } ?? from
        if to != from {
            // Перестановка и сдвиг значка — одной анимацией: место под ним едет, а он остаётся под курсором
            list.remove(at: from)
            list.insert(s, at: to)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                model.spaces = list
                dragX = x - slots[to]
            }
        } else {
            dragX = x - slots[to]
        }
    }

    fileprivate func endSpaceDrag() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { dragX = 0; dragID = nil }
        model.save()
    }
}

// MARK: - Командная строка

struct CommandBarView: View {
    @Environment(BrowserModel.self) private var model
    @FocusState private var focused: Bool
    /// Появление: строка проявляется и чуть опускается на место (без масштаба — иначе текст дрожит)
    @State private var appeared = false

    var body: some View {
        @Bindable var model = model
        let items = model.suggestions
        let pos = model.commandPos
        // Верх строки стоит на месте, список растёт вниз — строка не прыгает, пока подбираются подсказки.
        // Экран не затемняем — строку отделяет от страницы широкая мягкая тень.
        // Клик мимо строки закрывает её (см. CommandBarPosition)
        GeometryReader { geo in

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(.secondary).font(.system(size: 16))
                    TextField(placeholder, text: $model.commandText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($focused)
                        .onSubmit { model.runCommand() }
                        .onChange(of: model.commandText) {
                            model.commandIndex = 0
                            if ![.history, .downloads, .archive].contains(model.commandBar) {
                                SearchSuggest.shared.update(model.commandText, incognito: model.currentSpace.isIncognito)
                            }
                        }
                    // История и загрузки — открыть целиком в отдельном окне
                    if model.commandBar == .history || model.commandBar == .downloads {
                        let history = model.commandBar == .history
                        Button { if history { HistoryWindow.show() } else { DownloadsWindow.show() } } label: {
                            HStack(spacing: 5) {
                                Text("Show All")
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(history ? "Show all history (\(Shortcuts.shared.text(.allHistory)))" : "Show all downloads (\(Shortcuts.shared.text(.allDownloads)))")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 54)

                if !items.isEmpty {
                    Divider()
                    let rows = VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                            SuggestionRow(item: s, selected: i == model.commandIndex)
                                .id(i)
                                .onTapGesture {
                                    model.commandIndex = i
                                    model.runCommand()
                                }
                        }
                    }
                    .padding(6)
                    if items.count > 12 {
                        // Длинный список (история, загрузки) — прокручивается, выбранная строка всегда видна
                        ScrollViewReader { proxy in
                            ScrollView { rows }
                                .frame(height: 12 * 36 + 12)
                                .onChange(of: model.commandIndex) { _, i in proxy.scrollTo(i) }
                        }
                    } else {
                        rows
                    }
                } else if [.history, .downloads, .archive].contains(model.commandBar) {
                    Divider()
                    Text(model.commandBar == .history ? "No history yet" : model.commandBar == .archive ? "No archived tabs" : "No downloads yet")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(height: 44)
                }
            }
            .frame(width: 620)
            .background {
                // Тени — отдельными размытыми фигурами под карточкой, а не .shadow у всей строки:
                // иначе строка целиком рисуется в картинку с тенью, и при смене высоты списка
                // текст сдвигается на полпикселя — буквы «дрожат» при наборе
                let shape = RoundedRectangle(cornerRadius: 14, style: .circular)
                ZStack {
                    ZStack {
                        shape.fill(Color.black.opacity(0.3)).blur(radius: 50).offset(y: 24)      // широкая мягкая ~100 pt
                        shape.fill(Color.black.opacity(0.14)).blur(radius: 6).offset(y: 2)       // чёткий край
                    }
                    // Тень только снаружи — под полупрозрачным стеклом её быть не должно
                    .mask {
                        ZStack { Rectangle().padding(-200); shape.blendMode(.destinationOut) }.compositingGroup()
                    }
                    // Стекло + 15% плотного фона — чтобы содержимое лучше читалось
                    shape.fill(.regularMaterial)
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.15))
                }
                .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .circular).stroke(Color.primary.opacity(0.1)))
            .overlay(alignment: .topTrailing) {
                // Точка-фиксатор в центре скругления правого верхнего угла
                PinDot(on: pos.pinned) { pos.togglePin() }
                    .padding(14 - PinDot.hit / 2)
            }
            .background(GeometryReader { g in
                let f = g.frame(in: .global)
                Color.clear.onAppear { pos.frame = f }.onChange(of: f) { pos.frame = f }
            })
            // Появление — проявляется и чуть опускается на место. Не масштабом: при масштабе (особенно с отскоком
            // пружины) текст поля перерисовывается на дробных размерах и дрожит
            .offset(y: appeared ? 0 : -8)
            .opacity(appeared ? 1 : 0)
            .offset(pos.offset)
            .frame(maxWidth: .infinity)
            // Панель закреплена — по центру страницы, а не всего окна
            .padding(.leading, model.sidebarVisible ? min(Metrics.sidebarWidth, max(0, geo.size.width - 620 - 16)) : 0)
            .padding(.top, max(40, geo.size.height * 0.2))
        }
        .onAppear {
            pos.opened(model: model)
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
        .onDisappear { pos.closed() }
        .onAppear {
            DispatchQueue.main.async {
                focused = true
                // Адрес текущей страницы выделен целиком — начал печатать, и он заменился
                if model.commandBar == .current {
                    DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                }
            }
        }
    }

    private var icon: String {
        switch model.commandBar {
        case .split: return "rectangle.split.2x1"
        case .current: return "arrow.turn.down.right"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        case .archive: return "archivebox"
        default: return "magnifyingglass"
        }
    }

    private var placeholder: String {
        switch model.commandBar {
        case .split: return "Open in split…"
        case .current: return "Address or search…"
        case .history: return "Search history…"
        case .downloads: return "Search downloads…"
        case .archive: return "Search archived tabs…"
        default: return "Search, address or !command…"
        }
    }
}

struct SuggestionRow: View {
    let item: Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch item {
            case .go(let label, let url):
                Image(systemName: label.hasPrefix("Open ") ? "arrow.up.right" : "magnifyingglass")
                    .frame(width: 18)
                Text(label).lineLimit(1)
                Spacer()
                Text(url.host ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
            case .tab(let t):
                Favicon(url: t.url).frame(width: 16, height: 16).frame(width: 18)
                Text(t.displayTitle).lineLimit(1)
                Spacer()
                Text("Switch to Tab").font(.system(size: 12)).foregroundStyle(.secondary)
            case .bang(let b):
                Text("!\(b.key)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 40, alignment: .leading)
                Text(b.name)
                Spacer()
                Text("Tab to select").font(.system(size: 12)).foregroundStyle(.secondary)
            case .search(let q, _):
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 18)
                Text(q).lineLimit(1)
                Spacer()
            case .history(let e):
                Favicon(url: e.url).frame(width: 16, height: 16).frame(width: 18)
                Text(e.title.isEmpty ? (e.url.host ?? e.url.absoluteString) : e.title).lineLimit(1)
                Text(e.url.host ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(e.lastVisit.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            case .action(let a):
                Image(systemName: a.icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                Text(a.title).lineLimit(1)
                Spacer()
                if !a.keys.isEmpty {
                    Text(a.keys).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .circular))
                }
            case .archived(let e):
                Favicon(url: e.url).frame(width: 16, height: 16).frame(width: 18)
                Text(e.title.isEmpty ? (e.url.host ?? e.url.absoluteString) : e.title).lineLimit(1)
                Text(e.space).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(e.closed.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            case .download(let snap):
                // Состояние — живое (строка списка — снимок на момент поиска)
                let d = DownloadStore.shared.items.first { $0.id == snap.id } ?? snap
                Image(nsImage: NSWorkspace.shared.icon(forFile: d.file.path)).resizable()
                    .frame(width: 16, height: 16).frame(width: 18)
                Text(d.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !d.done && !d.failed {
                    let p = DownloadStore.shared.progress[d.id]
                    Text(p.map { $0 >= 0 ? "\(Int($0 * 100))%" : "Downloading…" } ?? "Downloading…")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    // Остановить загрузку
                    Button { DownloadStore.shared.cancel(d.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                } else {
                    Text(d.cancelled == true ? "Cancelled" : d.failed ? "Failed" : "Show in Finder")
                        .font(.system(size: 12)).foregroundStyle(d.failed && d.cancelled != true ? Color.red.opacity(0.8) : .secondary)
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
        .contentShape(Rectangle())
    }
}

// MARK: - Край страницы до края окна

/// Крайний левый столбик пикселей страницы, растянутый вширь: фон окна и «мостик» продолжают край страницы
/// (белая шапка — белым, тёмное ниже — тёмным). Пока столбика нет — просто цвет сайта.
struct PageEdgeFill: View {
    let tab: Tab?
    let fallback: NSColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color(nsColor: fallback)
                if let s = tab?.edgeStrip {
                    Image(nsImage: s.image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: g.size.width, height: s.height)
                        .offset(y: s.top - g.frame(in: .global).minY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Вкладка открыта не профилем своего пространства («Open As») — метка цвета профиля; одноразовая — песочные часы
struct ProfileBadge: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    /// Крупный — в строке вкладки слева от значка сайта (кружок с буквой профиля); мелкий — точка на значке
    var large = false
    var body: some View {
        let d: CGFloat = large ? 15 : 10
        if tab.temporary {
            Image(systemName: "hourglass").font(.system(size: large ? 8.5 : 6.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: d, height: d)
                .background(Color(white: 0.45), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(large ? 0.5 : 0.9), lineWidth: 1))
                .help("Temporary container — erased when the tab closes")
        } else if tab.profileOverride == Profile.vpnID {
            // Сайт с «Through VPN» — общий ящик VPN
            Image(systemName: "lock.shield.fill").font(.system(size: large ? 8.5 : 6, weight: .bold)).foregroundStyle(.white)
                .frame(width: d, height: d)
                .background(Color.green.opacity(0.85), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(large ? 0.5 : 0.9), lineWidth: 1))
                .help("Through the VPN — its own logins, shared by all VPN sites")
        } else if let id = tab.profileOverride, let p = model.profiles.first(where: { $0.id == id }) {
            Group {
                if large {
                    Text(String(p.name.prefix(1)).uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: d, height: d)
                        .background(p.color, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                } else {
                    Circle().fill(p.color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                }
            }
            .help("Opened as “\(p.name)”")
        }
    }
}

/// Инкогнито идёт напрямую (выключено «Only through the VPN proxy») — плашка вверху списка
struct IncognitoDirectNotice: View {
    @AppStorage(Prefs.incognitoProxy) private var proxyOn = false
    var body: some View {
        if !proxyOn {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Not through VPN").font(.system(size: 12, weight: .semibold))
                    Text("Sites see your real address").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Turn On") {
                    proxyOn = true
                    // Инкогнито пересоздаётся на новом хранилище — уже через прокси
                    Incognito.settingsChanged()
                }
                .controlSize(.small)
                .help("Incognito goes only through the VPN proxy — Settings → Privacy")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .circular))
            .padding(.bottom, 4)
        }
    }
}


/// Инкогнито: вместо линии «Temp» — «Erase All»: под курсором краснеет, клик — закрыть инкогнито и стереть всё
struct EraseIncognitoLine: View {
    @Environment(BrowserModel.self) private var model
    let space: Space
    @State private var hover = false
    private static let width: CGFloat = 84
    var body: some View {
        SectionLine(fold: false, labelWidth: Self.width) {
            Button { model.closeIncognito(space) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eraser").font(.system(size: 9.5, weight: .bold))
                    Text("Erase All").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(hover ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .frame(width: Self.width, height: 20)
                .background(hover ? Color.red.opacity(0.85) : Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: hover)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Close incognito and erase everything: tabs, cookies, site data, cache")
        } trailing: { EmptyView() }
    }
}

/// Крестик строки вкладки. У временной — закрыть (в архив). У вкладки закреплённого блока (и его папок):
/// клик — только закрыть (выгрузить, остаётся в списке, как ⌘W); задержал курсор 0,6 с — крестик краснеет,
/// клик — удалить вкладку совсем
struct RowCloseButton: View {
    @Environment(BrowserModel.self) private var model
    let tab: Tab
    let saved: Bool
    let style: AnyShapeStyle
    @State private var armed = false
    @State private var work: DispatchWorkItem?

    var body: some View {
        Button {
            if !saved { model.close(tab) }
            else if armed { model.close(tab) }
            else { model.unload(saved: tab) }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(armed ? AnyShapeStyle(Color.white) : style)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.red.opacity(armed ? 0.85 : 0)))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: armed)
        }
        .buttonStyle(.plain)
        .onHover { on in
            work?.cancel()
            guard saved, on else { armed = false; return }
            let w = DispatchWorkItem { armed = true }
            work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.72, execute: w)
        }
        .onDisappear { work?.cancel() }
        .help(!saved ? "Close tab" : armed ? "Delete tab" : "Close tab · hold the pointer to delete")
    }
}


/// Стопка уведомлений: значок, текст, кнопка действия; под курсором не исчезает, крестик — убрать
struct NoticeStack: View {
    @Environment(BrowserModel.self) private var model
    var fromBottom = false

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.inset) {
            ForEach(fromBottom ? model.notices : model.notices.reversed()) { n in
                NoticeCapsule(notice: n)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.notices)
    }
}

private struct NoticeCapsule: View {
    @Environment(BrowserModel.self) private var model
    let notice: Notice
    /// Высота капсулы; значок и кнопка внутри — концентричные ей круг и капсула на отступе inset
    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            if let icon = notice.icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .frame(width: Self.height - Metrics.inset * 2, height: Self.height - Metrics.inset * 2)
                    .background(Color.primary.opacity(Metrics.blockShade), in: Circle())
            }
            Text(notice.text).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                .padding(.leading, notice.icon == nil ? Self.height / 2 - Metrics.inset : 0)
            if let action = notice.action {
                Button {
                    notice.run?()
                    model.dismiss(notice)
                } label: {
                    Text(action).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: Self.height - Metrics.inset * 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: Self.height / 2 - Metrics.inset * 2, height: 1)
            }
        }
        .padding(Metrics.inset)
        .frame(height: Self.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        .onHover { h in
            if let i = model.notices.firstIndex(where: { $0.id == notice.id }) { model.notices[i].hovered = h }
        }
        .onTapGesture { if notice.action == nil { model.dismiss(notice) } }
    }
}


/// Свой угол окна `Metrics.windowRadius`: скрытая настройка окна (`_setCornerRadius:`) — форма окна, тень и обводка
/// у самой системы, без обрезки содержимого (обрезка слоем перерисовывала всё окно на каждом кадре — попапы и
/// анимации подтормаживали, а из-под угла торчал системный угол 16). Во весь экран — без скругления.
/// Нет такой настройки — запасной путь: прозрачное окно и обрезка слоя. Ставится фоном корневого вида окна
struct WindowCorner: NSViewRepresentable {
    var radius: CGFloat = Metrics.windowRadius
    private static let setSel = NSSelectorFromString("_setCornerRadius:")
    final class V: NSView {
        var radius: CGFloat = 0
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let w = window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.apply() })
            }
            apply()
        }
        func apply() {
            guard let w = window else { return }
            let r: CGFloat = w.styleMask.contains(.fullScreen) ? 0 : radius
            if w.responds(to: WindowCorner.setSel), let m = w.method(for: WindowCorner.setSel) {
                typealias F = @convention(c) (AnyObject, Selector, CGFloat) -> Void
                unsafeBitCast(m, to: F.self)(w, WindowCorner.setSel, r)
                w.invalidateShadow()
                return
            }
            guard let content = w.contentView else { return }
            if w.isOpaque || w.backgroundColor != .clear { w.isOpaque = false; w.backgroundColor = .clear }
            content.wantsLayer = true
            guard let layer = content.layer, layer.cornerRadius != r || !layer.masksToBounds else { return }
            layer.cornerRadius = r
            layer.cornerCurve = .circular
            layer.masksToBounds = true
            w.invalidateShadow()
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.radius = radius; return v }
    func updateNSView(_ v: V, context: Context) { if v.radius != radius { v.radius = radius; v.apply() } }
}
