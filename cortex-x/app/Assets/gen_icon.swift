// Generates the CortexX app icon: ink squircle, hairline border, three
// ascending ember candlesticks. Run: swift gen_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Canvas: transparent margins per Apple icon grid, squircle-ish rounded rect.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = rect.width * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Ink background with a faint vertical lift.
ctx.addPath(path)
ctx.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x131318), color(0x0A0A0C)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Three ascending ember candles with wicks.
let ember = color(0xE08A2A)
let emberDim = color(0xB56F1E)
let candleW: CGFloat = 108
let wickW: CGFloat = 18
let gap: CGFloat = 78
let baseY = rect.minY + rect.height * 0.24
let totalW = candleW * 3 + gap * 2
var x = rect.midX - totalW / 2

let bodies: [(CGFloat, CGFloat)] = [(80, 170), (190, 210), (300, 250)] // (bottom offset, height)
let wicks: [(CGFloat, CGFloat)] = [(40, 250), (150, 300), (260, 340)]

for i in 0..<3 {
    let (wb, wh) = wicks[i]
    ctx.setFillColor(i == 2 ? ember : emberDim)
    ctx.fill(CGRect(x: x + candleW / 2 - wickW / 2, y: baseY + wb, width: wickW, height: wh))
    let (bb, bh) = bodies[i]
    let body = CGRect(x: x, y: baseY + bb, width: candleW, height: bh)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.addPath(bodyPath)
    ctx.setFillColor(i == 2 ? ember : emberDim)
    ctx.fillPath()
    x += candleW + gap
}

// Hairline border on top.
ctx.resetClip()
ctx.addPath(path)
ctx.setStrokeColor(color(0x26262E))
ctx.setLineWidth(6)
ctx.strokePath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
