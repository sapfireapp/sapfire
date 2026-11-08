import AppKit
// cutout in.png out.png — камень на белом → камень на прозрачном. Фон — белое, связанное с краем картинки
// (заливкой от краёв), поэтому белый блик внутри камня остаётся. Край сглаживается по «белизне» пикселя.
let a = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
let w = src.pixelsWide, h = src.pixelsHigh
var rgb = [[Double]](repeating: [0, 0, 0], count: w * h)
for y in 0..<h { for x in 0..<w {
    let c = src.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    rgb[y * w + x] = [c.redComponent, c.greenComponent, c.blueComponent]
} }
func whiteness(_ i: Int) -> Double { rgb[i].min()! }          // 1 — чисто белый
// Заливка фона от краёв: почти белые пиксели, связанные с краем
var bg = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack += [x, (h - 1) * w + x] }
for y in 0..<h { stack += [y * w, y * w + w - 1] }
while let i = stack.popLast() {
    if bg[i] || whiteness(i) < 0.97 { continue }
    bg[i] = true
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }; if y < h - 1 { stack.append(i + w) }
}
var px = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h { for x in 0..<w {
    let i = y * w + x
    if bg[i] { continue }
    // Край (сосед — фон): пиксель — смесь цвета камня с белым; альфа = насколько он не белый
    var edge = false
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
        let nx = x + dx, ny = y + dy
        if nx >= 0, nx < w, ny >= 0, ny < h, bg[ny * w + nx] { edge = true }
    }
    var c = rgb[i], al = 1.0
    if edge {
        al = max(0.02, min(1, 1 - whiteness(i)))
        c = c.map { max(0, min(1, ($0 - (1 - al)) / al)) }   // убрать примесь белого
    }
    // Предумноженная альфа (так ждёт CGContext)
    for k in 0..<3 { px[i * 4 + k] = UInt8((c[k] * al * 255).rounded()) }
    px[i * 4 + 3] = UInt8((al * 255).rounded())
} }
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dst)
