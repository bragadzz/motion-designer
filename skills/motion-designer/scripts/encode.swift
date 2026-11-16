import AVFoundation
import ImageIO

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: encode <frames-dir> <out.mp4> [fps=60] [mbps=5] [qpmax=18]"); exit(1) }
let framesDir = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[2])
let fps = Int32(a.count > 3 ? a[3] : "60")!
let mbps = Double(a.count > 4 ? a[4] : "5")!
let qpmax = Int(a.count > 5 ? a[5] : "18")!
let files = try FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)
  .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else { print("no frames in \(framesDir.path)"); exit(1) }

func load(_ u: URL) -> CGImage {
  guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  else { print("could not read \(u.path)"); exit(1) }
  return img
}
let first = load(files[0])
let W = first.width, H = first.height

let color: [String: Any] = [
  AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
  AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
  AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
]
try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264,
  AVVideoWidthKey: W,
  AVVideoHeightKey: H,
  AVVideoColorPropertiesKey: color,
  AVVideoCompressionPropertiesKey: [
    AVVideoAverageBitRateKey: Int(mbps * 1_000_000),
    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
    AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
    AVVideoMaxKeyFrameIntervalDurationKey: 2,
    AVVideoAllowFrameReorderingKey: true,
    AVVideoExpectedSourceFrameRateKey: Int(fps),
    "MaxAllowedFrameQP": qpmax,
  ] as [String: Any],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: W,
  kCVPixelBufferHeightKey as String: H,
  kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
])
writer.add(input)
guard writer.startWriting() else { print("failed: \(writer.error!)"); exit(1) }
writer.startSession(atSourceTime: .zero)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let t0 = Date()
var i = 0
let finished = DispatchSemaphore(value: 0)
input.requestMediaDataWhenReady(on: DispatchQueue(label: "encode")) {
  while input.isReadyForMoreMediaData {
    if i == files.count { input.markAsFinished(); finished.signal(); return }
    autoreleasepool {
      let img = i == 0 ? first : load(files[i])
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
      let b = pb!
      CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      CVPixelBufferLockBaseAddress(b, [])
      let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: img.colorSpace ?? srgb,
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
      CVPixelBufferUnlockBaseAddress(b, [])
      if !adaptor.append(b, withPresentationTime: CMTime(value: Int64(i), timescale: fps)) {
        print("append failed at frame \(i): \(writer.error.map { "\($0)" } ?? "?")"); exit(1)
      }
    }
    i += 1
  }
}
finished.wait()
let closed = DispatchSemaphore(value: 0)
writer.finishWriting { closed.signal() }
closed.wait()
guard writer.status == .completed else { print("failed: \(writer.error.map { "\($0)" } ?? "?")"); exit(1) }
let outDir = out.deletingLastPathComponent()
for f in (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [] where f.hasPrefix(out.lastPathComponent + ".sb-") {
  try? FileManager.default.removeItem(at: outDir.appendingPathComponent(f))
}
let mb = Double((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! NSNumber).intValue) / 1_000_000
print(String(format: "done: %d frames, target %.1f Mbps, QP ≤ %d → %@ (%.2f MB) in %.1f s", files.count, mbps, qpmax, out.path, mb, Date().timeIntervalSince(t0)))
