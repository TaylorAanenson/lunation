// make-background.swift — regenerates dmg/background.png, the DMG install-window
// backdrop (1080x760, i.e. 2x the 540x380 window for Retina).
//   swift dmg/make-background.swift dmg/background.png
// Icon layout in build-dmg.sh must match: app at (140,190), Applications at
// (400,190) in the 540x380 window; the arrow is drawn at that midpoint.
import AppKit

let W = 1080, H = 760
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
func col(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex>>16)&0xff)/255, green: CGFloat((hex>>8)&0xff)/255,
            blue: CGFloat(hex&0xff)/255, alpha: a) }

// radial gradient, bright toward the top
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [col(0x1c2030).cgColor, col(0x101218).cgColor, col(0x0b0c11).cgColor] as CFArray,
    locations: [0, 0.6, 1])!
ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 540, y: 700), startRadius: 0,
    endCenter: CGPoint(x: 540, y: 700), endRadius: 880, options: [.drawsAfterEndLocation])

for (x,y,a) in [(150.0,640.0,0.5),(930.0,675.0,0.45),(820.0,585.0,0.35),(250.0,520.0,0.4),(1010.0,470.0,0.3),(70.0,430.0,0.3)] {
    col(0xffffff, CGFloat(a)).setFill()
    NSBezierPath(ovalIn: CGRect(x: x-1.5, y: y-1.5, width: 3, height: 3)).fill() }

// small half-moon left of the title
let mcx: CGFloat = 452, mcy: CGFloat = 678, R: CGFloat = 17, Rf: CGFloat = 14
let ring = NSBezierPath(ovalIn: CGRect(x: mcx-R, y: mcy-R, width: 2*R, height: 2*R))
ring.lineWidth = 3; col(0xcbd0dd, 0.7).setStroke(); ring.stroke()
let lit = NSBezierPath(); lit.move(to: CGPoint(x: mcx, y: mcy+Rf))
lit.appendArc(withCenter: CGPoint(x: mcx, y: mcy), radius: Rf, startAngle: 90, endAngle: -90, clockwise: true)
lit.close(); col(0xe8ebf2).setFill(); lit.fill()

func text(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ hex: UInt32, cx: CGFloat? = nil, x: CGFloat = 0, y: CGFloat) {
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: col(hex)]
    let str = NSAttributedString(string: s, attributes: a)
    let px = cx != nil ? cx! - str.size().width/2 : x
    str.draw(at: CGPoint(x: px, y: y)) }

text("Lunation", 46, .semibold, 0xeef0f4, x: 484, y: 660)
text("Drag the app into your Applications folder", 25, .regular, 0x9b9ea8, cx: 540, y: 596)
text("lunation.dev", 21, .regular, 0x5a6070, cx: 540, y: 40)

// arrow at vertical center
col(0x8b93a8).setStroke()
for pts in [[(452.0,380.0),(612,380)], [(612.0,396.0),(636,380),(612,364)]] {
    let p = NSBezierPath(); p.lineWidth = 6; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for pt in pts.dropFirst() { p.line(to: CGPoint(x: pt.0, y: pt.1)) }
    p.stroke() }

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote", CommandLine.arguments[1])
