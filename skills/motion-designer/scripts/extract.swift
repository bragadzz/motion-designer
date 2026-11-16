import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: extract <video> <out-dir> [step=1.0]"); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let step = a.count > 3 ? Double(a[3])! : 1.0
let dur = try await asset.load(.duration).seconds
try FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
for t in stride(from: 0.0, to: dur, by: step) {
  let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
  let u = URL(fileURLWithPath: a[2]).appendingPathComponent(String(format: "f%06.2f.png", t))
  let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
print("ok \(dur) s")
