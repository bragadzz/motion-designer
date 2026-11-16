import AVFoundation

let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: mix <voice.mp3> <marks.txt> <out.wav> [duration=15]"); exit(1) }
let rate = 44100
let N = Int((Double(a.count > 4 ? a[4] : "15")! * Double(rate)).rounded())
let ceiling: Float = pow(10, -1 / 20)

func decode(_ url: URL) async throws -> (samples: [Float], sourceRate: Double) {
  let asset = AVURLAsset(url: url)
  guard let t = try await asset.loadTracks(withMediaType: .audio).first else { print("no audio: \(url.path)"); exit(1) }
  let fmt = try await t.load(.formatDescriptions).first!
  let r = try AVAssetReader(asset: asset)
  let o = AVAssetReaderTrackOutput(track: t, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
  ])
  r.add(o)
  r.startReading()
  var s: [Float] = []
  while let sb = o.copyNextSampleBuffer() {
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
    var tmp = [Float](repeating: 0, count: CMBlockBufferGetDataLength(bb) / 4)
    CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: tmp.count * 4, destination: &tmp)
    s += tmp
  }
  guard r.status == .completed else { print("could not decode \(url.path): \(r.error.map { "\($0)" } ?? "?")"); exit(1) }
  return (s, CMAudioFormatDescriptionGetStreamBasicDescription(fmt)!.pointee.mSampleRate)
}

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
  let end = frames > 0 ? Int((Double(frames * perFrame - padding) * scale).rounded()) : Int.max / 2
  return (Int((Double(delay) * scale).rounded()), end)
}

let voiceURL = URL(fileURLWithPath: a[1])
let (rawVoice, voiceRate) = try await decode(voiceURL)
let trim = gaplessMP3(voiceURL, voiceRate) ?? (0, rawVoice.count)
let voice = Array(rawVoice[trim.start..<min(trim.end, rawVoice.count)])
guard voice.count <= N else { print("the voice (\(Double(voice.count) / Double(rate)) s) is longer than the duration"); exit(1) }
var v = [Float](repeating: 0, count: N)
v.replaceSubrange(0..<voice.count, with: voice)

func clean(_ x: [Float]) -> [Float] {
  let mean = x.reduce(0, +) / Float(x.count)
  let rc: Float = 1 / (2 * .pi * 20), dt: Float = 1 / Float(rate), al = rc / (rc + dt)
  var y = [Float](repeating: 0, count: x.count), prev: Float = 0, hp: Float = 0
  for i in x.indices { let v = x[i] - mean; hp = al * (hp + v - prev); prev = v; y[i] = hp }
  let fi = Int(0.003 * Double(rate)), fo = Int(0.010 * Double(rate))
  for i in 0..<min(fi, y.count) { y[i] *= Float(i) / Float(fi) }
  for i in 0..<min(fo, y.count) { y[y.count - 1 - i] *= Float(i) / Float(fo) }
  return y
}

struct Effect { let t: Double; let name: String; let target: Double; let start: Int; let s: [Float]; var gain: Float }
let marksURL = URL(fileURLWithPath: a[2]), sfxDir = marksURL.deletingLastPathComponent()
var cache: [String: [Float]] = [:]
var effects: [Effect] = []
var ducks: [(t: Double, margin: Double)] = []
for line in try String(contentsOf: marksURL, encoding: .utf8).split(separator: "\n") {
  let c = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-").split(whereSeparator: { $0 == " " || $0 == "\t" })
  if c.isEmpty { continue }
  guard c.count == 3, let t = Double(c[0]), let target = Double(c[2]) else { print("invalid line in marks file: \(line)"); exit(1) }
  let name = String(c[1])
  if name == "duck" { ducks.append((t, target)); continue }
  if cache[name] == nil { cache[name] = clean(try await decode(sfxDir.appendingPathComponent(name + ".wav")).samples) }
  let s = cache[name]!, peak = s.map(abs).max()!
  effects.append(Effect(t: t, name: name, target: target, start: Int((t * Double(rate)).rounded()), s: s, gain: pow(10, Float(target) / 20) / peak))
}

func rms(_ x: [Float], _ before: Double, _ after: Double) -> [Float] {
  let b0 = Int(before * Double(rate)), a0 = Int(after * Double(rate))
  var pref = [Double](repeating: 0, count: x.count + 1)
  for i in x.indices { pref[i + 1] = pref[i] + Double(x[i] * x[i]) }
  return x.indices.map { i in let lo = max(0, i - b0), hi = min(x.count, i + a0); return Float(sqrt((pref[hi] - pref[lo]) / Double(max(1, hi - lo)))) }
}
func sumEffects() -> [Float] {
  var e = [Float](repeating: 0, count: N)
  for ef in effects { for i in ef.s.indices where ef.start + i < N { e[ef.start + i] += ef.gain * ef.s[i] } }
  return e
}
var ducking = [Float](repeating: 1, count: N)
if !ducks.isEmpty {
  let vAhead = rms(v, 0.01, 0.03), vMid = rms(v, 0.01, 0.01), eEnv = rms(sumEffects(), 0.01, 0.01), minGain: Float = pow(10, -24 / 20)
  var target = [Float](repeating: 1, count: N)
  for (t, margin) in ducks {
    let m = pow(10, Float(-abs(margin)) / 20), i0 = max(0, Int((t - 0.03) * Double(rate))), i1 = min(N, Int((t + 0.6) * Double(rate)))
    for n in i0..<i1 where eEnv[n] > 1e-6 { target[n] = min(target[n], max(minGain, min(1, m * min(vAhead[n], vMid[n]) / eEnv[n]))) }
  }
  let ah = Int(0.008 * Double(rate))
  let targetAhead = (0..<N).map { n in target[n..<min(N, n + ah)].min()! }
  let attack = Float(exp(-1 / (0.003 * Double(rate)))), release = Float(exp(-1 / (0.1 * Double(rate))))
  var g: Float = 1
  for n in 0..<N { let k = targetAhead[n] < g ? attack : release; g = targetAhead[n] + (g - targetAhead[n]) * k; ducking[n] = g }
}

var mix = v, peakBefore: Float = 0
for pass in 0..<20 {
  var e = sumEffects()
  for n in 0..<N { e[n] *= ducking[n] }
  mix = zip(v, e).map(+)
  if pass == 0 { peakBefore = mix.map(abs).max()! }
  var factor = [Float](repeating: 1, count: effects.count), over = false
  for n in 0..<N where abs(mix[n]) > ceiling {
    over = true
    let k = max(0, ((mix[n] > 0 ? ceiling : -ceiling) - v[n]) / e[n])
    for (j, ef) in effects.enumerated() where n >= ef.start && n < ef.start + ef.s.count && ef.s[n - ef.start] != 0 { factor[j] = min(factor[j], k * 0.999) }
  }
  if !over { break }
  for j in effects.indices { effects[j].gain *= factor[j] }
}
let db = { (x: Float) in String(format: "%.2f dBFS", 20 * log10(x)) }
print("voice: \(String(format: "%.3f", Double(voice.count) / Double(rate))) s (trimmed \(trim.start) samples of MP3 encoder delay), peak \(db(voice.map(abs).max()!))")
for ef in effects {
  let peak = ef.s.map(abs).max()! * ef.gain, lowered = 20 * log10(peak) - Float(ef.target)
  print(String(format: "  %6.2f s  %@ peak %6.2f dBFS%@", ef.t, ef.name as NSString, 20 * log10(peak), abs(lowered) > 0.01 ? String(format: "  (lowered %.2f dB to fit)", -lowered) : ""))
}
print("mix: peak \(db(mix.map(abs).max()!)) (before adjustment \(db(peakBefore)), ceiling −1 dBFS)")
if !ducks.isEmpty {
  let vEnv = rms(v, 0.01, 0.01), eEnv = rms(zip(mix, v).map(-), 0.01, 0.01)
  for (t, _) in ducks {
    let i0 = Int(t * Double(rate)), i1 = min(N, Int((t + 0.6) * Double(rate)))
    let speech = (i0..<i1).filter { vEnv[$0] > 0.03 }
    guard let n = speech.max(by: { eEnv[$0] / vEnv[$0] < eEnv[$1] / vEnv[$1] }) else { continue }
    print(String(format: "  duck %6.2f s: effects at most %+.1f dB relative to the voice (%.3f s, voice %.0f dBFS RMS)", t, 20 * log10(max(eEnv[n], 1e-9) / vEnv[n]), Double(n) / Double(rate), 20 * log10(vEnv[n])))
  }
}

let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(N))!
buf.frameLength = AVAudioFrameCount(N)
mix.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: N) }
let out = URL(fileURLWithPath: a[3])
try? FileManager.default.removeItem(at: out)
let file = try AVAudioFile(forWriting: out, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
try file.write(from: buf)
file.close()
print("done: \(out.path) (\(String(format: "%.3f", Double(N) / Double(rate))) s, 44.1 kHz mono float32)")
