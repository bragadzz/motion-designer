import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: verify <video.mp4> [source-frames-dir] [frame frame frame]"); exit(1) }
let url = URL(fileURLWithPath: a[1])
let source: [URL] = a.count > 2 ? (try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: a[2]), includingPropertiesForKeys: nil)
  .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }) : []

let asset = AVURLAsset(url: url)
let track = try await asset.loadTracks(withMediaType: .video).first!
let dur = try await asset.load(.duration)
let (fps, size, fmts) = try await track.load(.nominalFrameRate, .naturalSize, .formatDescriptions)
let fd = fmts.first!
let st = CMFormatDescriptionGetMediaSubType(fd).bigEndian
let codec = withUnsafeBytes(of: st) { String(decoding: $0, as: UTF8.self) }
let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
var profile = "?"
if let avcC = (ext["SampleDescriptionExtensionAtoms"] as? [String: Any])?["avcC"] as? Data, avcC.count > 3 {
  let names: [UInt8: String] = [66: "Baseline", 77: "Main", 100: "High"]
  profile = "\(names[avcC[1]] ?? "profile \(avcC[1])") level \(Double(avcC[3]) / 10)"
}
let colorTags = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
  .map { ext[$0 as String] as? String ?? "-" }.joined(separator: " / ")
let range = (ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) == true ? "full" : "video (16-235)"

let reader = try AVAssetReader(asset: asset)
let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
reader.add(readerOutput)
reader.startReading()
var frameCount = 0, keyframes: [Int] = []
while let sb = readerOutput.copyNextSampleBuffer() {
  let n = CMSampleBufferGetNumSamples(sb)
  if n == 0 { continue }
  let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
  if (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true {
    keyframes.append(Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * Double(fps)).rounded()))
  }
  frameCount += n
}

let bytes = try Data(contentsOf: url)
var atoms: [String] = [], p = 0
while p + 8 <= bytes.count {
  var t = Int(bytes[p..<p + 4].reduce(0) { $0 << 8 | UInt64($1) })
  if t == 1, p + 16 <= bytes.count { t = Int(bytes[p + 8..<p + 16].reduce(0) { $0 << 8 | UInt64($1) }) }
  atoms.append(String(decoding: bytes[p + 4..<p + 8], as: UTF8.self))
  if t < 8 { break }
  p += t
}

print(String(format: "duration %.3f s · %.2f fps · %d frames · %dx%d · %@ %@ · %.2f MB (%.2f Mbps)",
             dur.seconds, fps, frameCount, Int(size.width), Int(size.height), codec, profile,
             Double(bytes.count) / 1_000_000, Double(bytes.count) * 8 / dur.seconds / 1_000_000))
print("color: \(colorTags) · range \(range) · keyframes at frames \(keyframes.map { $0 - keyframes[0] }) · atoms: \(atoms.joined(separator: " "))\(atoms.firstIndex(of: "moov")! < atoms.firstIndex(of: "mdat")! ? " (faststart ok)" : " (MOOV AT END)")")

if let at = try await asset.loadTracks(withMediaType: .audio).first {
  let (afs, ar, dataRate) = try await at.load(.formatDescriptions, .timeRange, .estimatedDataRate)
  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(afs.first!)!.pointee
  let fcc = withUnsafeBytes(of: asbd.mFormatID.bigEndian) { String(decoding: $0, as: UTF8.self) }
  print(String(format: "audio: %@ · %d channel(s) · %.0f Hz · %.0f kbps · starts at %.3f s · lasts %.3f s",
               fcc, asbd.mChannelsPerFrame, asbd.mSampleRate, dataRate / 1000, ar.start.seconds, ar.duration.seconds))
} else { print("audio: none") }

func pixels(_ img: CGImage) -> [UInt8] {
  var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
  let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
  return buf
}

let frames = a.count > 3 ? a[3...].map { Int($0)! } : [frameCount / 4, frameCount / 2, frameCount * 3 / 4]
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let base = url.deletingPathExtension().path
for q in frames {
  let (img, actual) = try await gen.image(at: CMTime(value: CMTimeValue(q), timescale: CMTimeScale(fps.rounded())))
  let png = URL(fileURLWithPath: "\(base)-f\(String(format: "%05d", q)).png")
  let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? img, nil)
  CGImageDestinationFinalize(dest)
  var line = String(format: "frame %d (t=%.4f s) → %@", q, actual.seconds, png.lastPathComponent)
  if q < source.count, let s = CGImageSourceCreateWithURL(source[q] as CFURL, nil), let orig = CGImageSourceCreateImageAtIndex(s, 0, nil) {
    let o = pixels(orig), d = pixels(img)
    var se = 0.0, whiteCount = 0, whiteSum = 0
    for k in stride(from: 0, to: o.count, by: 4) {
      for c in 0..<3 { let e = Double(o[k + c]) - Double(d[k + c]); se += e * e }
      if o[k] == 255 && o[k + 1] == 255 && o[k + 2] == 255 { whiteCount += 1; whiteSum += Int(d[k]) + Int(d[k + 1]) + Int(d[k + 2]) }
    }
    let psnr = 10 * log10(255.0 * 255.0 / (se / Double(o.count / 4 * 3)))
    let corner = 4 * (20 * orig.width + 20)
    line += String(format: " · PSNR %.1f dB · corner (20,20) source %d,%d,%d → mp4 %d,%d,%d", psnr, o[corner], o[corner + 1], o[corner + 2], d[corner], d[corner + 1], d[corner + 2])
    if whiteCount > 0 { line += String(format: " · white 255 → %.1f (%d px)", Double(whiteSum) / Double(whiteCount * 3), whiteCount) }
  }
  print(line)
}
