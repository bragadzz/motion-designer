import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: sheet <video.mp4> <sheet.png> [step=0.25] [columns=6]"); exit(1) }
let step = a.count > 3 ? Double(a[3])! : 0.25
let cols = a.count > 4 ? Int(a[4])! : 6
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let dur = try await asset.load(.duration).seconds
let fps = try await asset.loadTracks(withMediaType: .video).first!.load(.nominalFrameRate)
let times = stride(from: 0.0, to: dur - 1e-9, by: step).map { $0 }
let (tw, th, band, gap) = (480, 270, 30, 6)
let rows = (times.count + cols - 1) / cols
let W = cols * tw + (cols + 1) * gap, H = rows * (th + band) + (rows + 1) * gap
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
for (n, t) in times.enumerated() {
  let q = Int((t * Double(fps)).rounded())
  let (img, _) = try await gen.image(at: CMTime(value: CMTimeValue(q), timescale: CMTimeScale(fps.rounded())))
  let x = gap + (n % cols) * (tw + gap), yTop = gap + (n / cols) * (th + band + gap)
  let y = H - yTop - th - band
  ctx.interpolationQuality = .high
  ctx.draw(img.copy(colorSpace: srgb) ?? img, in: CGRect(x: x, y: y + band, width: tw, height: th))
  let label = NSAttributedString(string: String(format: "%.2f s · f%d", t, q), attributes: [
    kCTFontAttributeName as NSAttributedString.Key: font,
    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.9, alpha: 1),
  ])
  ctx.textPosition = CGPoint(x: x + 4, y: y + 8)
  CTLineDraw(CTLineCreateWithAttributedString(label), ctx)
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { print("could not write \(a[2])"); exit(1) }
print("sheet: \(times.count) frames (every \(step) s) → \(a[2]) (\(W)x\(H))")
