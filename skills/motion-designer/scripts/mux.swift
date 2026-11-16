import AVFoundation

let a = CommandLine.arguments
guard a.count == 4 else { print("usage: mux <video.mp4> <audio.mp3|wav|m4a> <out.mp4>"); exit(1) }
let vAsset = AVURLAsset(url: URL(fileURLWithPath: a[1])), aAsset = AVURLAsset(url: URL(fileURLWithPath: a[2]))
let out = URL(fileURLWithPath: a[3])
guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
      let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first else { print("missing video or audio track"); exit(1) }
let dur = try await vAsset.load(.duration)
let vFmt = try await vTrack.load(.formatDescriptions).first!
let aFmt = try await aTrack.load(.formatDescriptions).first!
let channels = Int(CMAudioFormatDescriptionGetStreamBasicDescription(aFmt)!.pointee.mChannelsPerFrame)
let rate = 44100
let total = Int((dur.seconds * Double(rate)).rounded())

func gaplessMP3(_ url: URL, _ sourceRate: Double) -> (start: Int, end: Int)? {
  guard url.pathExtension.lowercased() == "mp3", let d = try? Data(contentsOf: url).prefix(16384) else { return nil }
  guard let r = d.range(of: Data("Info".utf8)) ?? d.range(of: Data("Xing".utf8)) else { return nil }
  let be = { (i: Int) in d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) } }
  let flags = be(r.lowerBound + 4)
  var q = r.lowerBound + 8, frames = 0
  if flags & 1 != 0 { frames = be(q); q += 4 }
  if flags & 2 != 0 { q += 4 }
  if flags & 4 != 0 { q += 100 }
  if flags & 8 != 0 { q += 4 }
  guard q + 24 <= d.count else { return nil }
  let delay = Int(d[q + 21]) << 4 | Int(d[q + 22]) >> 4, padding = (Int(d[q + 22]) & 0xF) << 8 | Int(d[q + 23])
  let scale = Double(rate) / sourceRate, perFrame = sourceRate >= 32000 ? 1152 : 576
  let end = frames > 0 ? frames * perFrame - padding : Int.max / 2
  return (Int((Double(delay) * scale).rounded()), end == Int.max / 2 ? end : Int((Double(end) * scale).rounded()))
}
let trim = gaplessMP3(URL(fileURLWithPath: a[2]), CMAudioFormatDescriptionGetStreamBasicDescription(aFmt)!.pointee.mSampleRate) ?? (0, Int.max / 2)

let vReader = try AVAssetReader(asset: vAsset)
let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
vReader.add(vOut)
let aReader = try AVAssetReader(asset: aAsset)
let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [
  AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
  AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
])
aReader.add(aOut)
guard vReader.startReading(), aReader.startReading() else { print("read failed: \(vReader.error ?? aReader.error!)"); exit(1) }

try? FileManager.default.removeItem(at: out)
nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFmt)
let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
  AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000,
])
vIn.expectsMediaDataInRealTime = false
aIn.expectsMediaDataInRealTime = false
writer.add(vIn)
writer.add(aIn)
guard writer.startWriting() else { print("failed: \(writer.error!)"); exit(1) }
writer.startSession(atSourceTime: .zero)

func fail(_ msg: String) -> Never { print("\(msg): \(writer.error.map { "\($0)" } ?? "?")"); exit(1) }

nonisolated(unsafe) var offset: CMTime?
func retime(_ sb: CMSampleBuffer) -> CMSampleBuffer {
  if offset == nil { offset = CMSampleBufferGetPresentationTimeStamp(sb) }
  guard let d = offset, d != .zero else { return sb }
  var n = 0
  CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &n)
  var t = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
  CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &t, entriesNeededOut: &n)
  for i in t.indices {
    t[i].presentationTimeStamp = t[i].presentationTimeStamp - d
    if t[i].decodeTimeStamp.isValid { t[i].decodeTimeStamp = t[i].decodeTimeStamp - d }
  }
  var copy: CMSampleBuffer?
  CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: n, sampleTimingArray: &t, sampleBufferOut: &copy)
  return copy!
}

func silence(_ frames: Int, _ fmt: CMAudioFormatDescription, _ pts: CMTime) -> CMSampleBuffer {
  let bytes = frames * Int(CMAudioFormatDescriptionGetStreamBasicDescription(fmt)!.pointee.mBytesPerFrame)
  var bb: CMBlockBuffer?
  CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                     offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
  CMBlockBufferFillDataBytes(with: 0, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes)
  var sb: CMSampleBuffer?
  CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fmt, sampleCount: frames,
                                                       presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
  return sb!
}

func slice(_ sb: CMSampleBuffer, _ from: Int, _ n: Int, _ pts: CMTime) -> CMSampleBuffer {
  var part: CMSampleBuffer? = sb
  if from > 0 || n < CMSampleBufferGetNumSamples(sb) {
    CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: sb, sampleRange: CFRange(location: from, length: n), sampleBufferOut: &part)
  }
  var t = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
  var copy: CMSampleBuffer?
  CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: part!, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleBufferOut: &copy)
  return copy!
}

let group = DispatchGroup()
group.enter()
vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "video")) {
  while vIn.isReadyForMoreMediaData {
    guard let sb = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); group.leave(); return }
    if CMSampleBufferGetNumSamples(sb) == 0 { continue }
    if !vIn.append(retime(sb)) { fail("video") }
  }
}
nonisolated(unsafe) var written = 0, consumed = 0, pcmFmt: CMAudioFormatDescription?
group.enter()
aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "audio")) {
  while aIn.isReadyForMoreMediaData {
    if let sb = aOut.copyNextSampleBuffer() {
      let n = CMSampleBufferGetNumSamples(sb)
      if n == 0 { continue }
      let from = max(0, trim.start - consumed), upTo = min(n, trim.end - consumed)
      consumed += n
      if upTo <= from { continue }
      if written + upTo - from > total { print("the audio is longer than the video (\(dur.seconds) s)"); exit(1) }
      pcmFmt = CMSampleBufferGetFormatDescription(sb)
      if !aIn.append(slice(sb, from, upTo - from, CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)))) { fail("audio") }
      written += upTo - from
    } else if written < total {
      let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate))
      if !aIn.append(silence(total - written, pcmFmt!, pts)) { fail("silence") }
      print(String(format: "audio: %.3f s (trimmed %d samples of MP3 encoder delay) · silence to the end: %.3f s", Double(written) / Double(rate), trim.start, Double(total - written) / Double(rate)))
      written = total
    } else { aIn.markAsFinished(); group.leave(); return }
  }
}
await withCheckedContinuation { c in group.notify(queue: .global()) { c.resume() } }
await writer.finishWriting()
guard writer.status == .completed else { fail("failed") }
let outDir = out.deletingLastPathComponent()
for f in (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [] where f.hasPrefix(out.lastPathComponent + ".sb-") {
  try? FileManager.default.removeItem(at: outDir.appendingPathComponent(f))
}
let mb = Double((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! NSNumber).intValue) / 1_000_000
print(String(format: "done: %@ (%.2f MB), video copied without re-encoding (offset %.4f s) + AAC %d ch 44.1 kHz 128 kbps", out.path, mb, offset?.seconds ?? 0, channels))
