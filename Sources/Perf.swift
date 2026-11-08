import Foundation
import SwiftUI

/// Выключатели надстроек для замеров (Speedometer и т. п.) — временно, по одной:
/// `defaults write app.sapfire.browser perfOff -string "blocker,probe,focus,scripts,opaque,ext"`
/// (внутри scripts по одному: rules, tweaks, css, geo, bridge, optclick, translate, pw, yt, capture, media, lastlink;
/// в блокировщике: blk-builtin, blk-easylist, blk-easyprivacy, blk-ruadlist, blk-cos — без правил скрытия, cos — без скрипта
/// скрытия, cos-obs / cos-survey / cos-flush — его части; thumbs — без миниатюр; clip — без обрезки страницы по форме;
/// inspect — без Web Inspector у страниц; throttle — без замедления таймеров фоновых страниц), `perfSleepMinutes` (число) — сон вкладок через столько минут вместо настройки (Settings → Tabs → Memory),
/// действует на вкладки, открытые после записи (у каждой своя конфигурация). Снять — `defaults delete app.sapfire.browser perfOff`.
enum Perf {
    static func off(_ key: String) -> Bool {
        (UserDefaults.standard.string(forKey: "perfOff") ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == key }
    }
}

extension View {
    /// Обрезка страницы по форме; `clip` в perfOff — без неё (замер цены маски поверх страницы)
    @ViewBuilder func pageClip<S: Shape>(_ shape: S) -> some View {
        if Perf.off("clip") { self } else { clipShape(shape) }
    }
}
