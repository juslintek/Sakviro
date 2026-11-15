import Foundation
import Accelerate
import AVFoundation

struct AudioAnomalyFinding: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Equatable, Sendable {
        case dcOffset
        case lowFrequencyRumble
        case mainsHum
        case clicksAndPops
        case clipping
        case backgroundHiss
        case lowLoudness
        case dropoutGaps
    }
    var id: String { "\(track):\(kind.rawValue)" }
    let track: String
    let kind: Kind
    let detail: String
    let fixed: Bool

    init(track: String, kind: Kind, detail: String, fixed: Bool) {
        self.track = track
        self.kind = kind
        self.detail = detail
        self.fixed = fixed
    }
}

struct AudioTrackMetrics: Codable, Equatable, Sendable {
    let track: String
    let sampleRate: Double
    let durationSeconds: Double
    let speechRMSdBFSBefore: Double
    let speechRMSdBFSAfter: Double
    let peakdBFSBefore: Double
    let peakdBFSAfter: Double
    let noiseFloordBFSBefore: Double
    let noiseFloordBFSAfter: Double
    let clickCount: Int
    let clippedSamples: Int
    let dcOffset: Double
    let humFrequencyHz: Int?

    init(
        track: String,
        sampleRate: Double,
        durationSeconds: Double,
        speechRMSdBFSBefore: Double,
        speechRMSdBFSAfter: Double,
        peakdBFSBefore: Double,
        peakdBFSAfter: Double,
        noiseFloordBFSBefore: Double,
        noiseFloordBFSAfter: Double,
        clickCount: Int,
        clippedSamples: Int,
        dcOffset: Double,
        humFrequencyHz: Int?
    ) {
        self.track = track
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.speechRMSdBFSBefore = speechRMSdBFSBefore
        self.speechRMSdBFSAfter = speechRMSdBFSAfter
        self.peakdBFSBefore = peakdBFSBefore
        self.peakdBFSAfter = peakdBFSAfter
        self.noiseFloordBFSBefore = noiseFloordBFSBefore
        self.noiseFloordBFSAfter = noiseFloordBFSAfter
        self.clickCount = clickCount
        self.clippedSamples = clippedSamples
        self.dcOffset = dcOffset
        self.humFrequencyHz = humFrequencyHz
    }
}

struct AudioQualityReport: Codable, Equatable, Sendable {
    let processedAt: Date
    let tracks: [AudioTrackMetrics]
    let anomalies: [AudioAnomalyFinding]
    let elapsedMs: Int

    var summaryText: String {
        let fixedCount = anomalies.filter(\.fixed).count
        if fixedCount == 0 {
            return "Audio clean & balanced"
        }
        return "Fixed \(fixedCount) audio issue\(fixedCount == 1 ? "" : "s")"
    }

    init(
        processedAt: Date = Date(),
        tracks: [AudioTrackMetrics],
        anomalies: [AudioAnomalyFinding],
        elapsedMs: Int
    ) {
        self.processedAt = processedAt
        self.tracks = tracks
        self.anomalies = anomalies
        self.elapsedMs = elapsedMs
    }

    init(
        processedAt: Date = Date(),
        tracks: [AudioTrackMetrics],
        anomalies: [AudioAnomalyFinding],
        elapsedMs: Double
    ) {
        self.processedAt = processedAt
        self.tracks = tracks
        self.anomalies = anomalies
        self.elapsedMs = Int(elapsedMs.rounded())
    }
}

enum AudioQualityCleaner {
    static let autoCleanKey = "autoCleanAudio"

    static var isAutoCleanEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCleanKey) as? Bool ?? true
    }

    static func cleanedPath(for originalPath: String) -> String {
        if originalPath.hasSuffix(".cleaned.caf") {
            return originalPath
        }
        let url = URL(fileURLWithPath: originalPath)
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        if dir.isEmpty || dir == "." {
            return stem + ".cleaned.caf"
        }
        return (dir as NSString).appendingPathComponent(stem + ".cleaned.caf")
    }

    // MARK: - Internal Biquad Filters

    struct BiquadHPF {
        private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        private var z1: Float = 0, z2: Float = 0

        init(cutoff: Double = 80.0, sampleRate: Double = 16000.0) {
            let w0 = 2.0 * Double.pi * cutoff / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let alpha = sinW0 / (2.0 * (1.0 / sqrt(2.0)))
            let a0 = 1.0 + alpha
            b0 = Float(((1.0 + cosW0) / 2.0) / a0)
            b1 = Float((-(1.0 + cosW0)) / a0)
            b2 = Float(((1.0 + cosW0) / 2.0) / a0)
            a1 = Float((-2.0 * cosW0) / a0)
            a2 = Float((1.0 - alpha) / a0)
        }

        mutating func processInPlace(_ samples: inout [Float]) {
            for i in 0..<samples.count {
                let x = samples[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                samples[i] = y
            }
        }
    }

    struct BiquadLPF {
        private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        private var z1: Float = 0, z2: Float = 0

        init(cutoff: Double = 85.0, sampleRate: Double = 16000.0) {
            let w0 = 2.0 * Double.pi * cutoff / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let alpha = sinW0 / (2.0 * (1.0 / sqrt(2.0)))
            let a0 = 1.0 + alpha
            b0 = Float(((1.0 - cosW0) / 2.0) / a0)
            b1 = Float((1.0 - cosW0) / a0)
            b2 = Float(((1.0 - cosW0) / 2.0) / a0)
            a1 = Float((-2.0 * cosW0) / a0)
            a2 = Float((1.0 - alpha) / a0)
        }

        mutating func process(_ samples: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: samples.count)
            for i in 0..<samples.count {
                let x = samples[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                out[i] = y
            }
            return out
        }
    }

    struct BiquadNotch {
        private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        private var z1: Float = 0, z2: Float = 0

        init(f0: Double, q: Double = 30.0, sampleRate: Double = 16000.0) {
            let w0 = 2.0 * Double.pi * f0 / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let alpha = sinW0 / (2.0 * q)
            let a0 = 1.0 + alpha
            b0 = Float(1.0 / a0)
            b1 = Float((-2.0 * cosW0) / a0)
            b2 = Float(1.0 / a0)
            a1 = Float((-2.0 * cosW0) / a0)
            a2 = Float((1.0 - alpha) / a0)
        }

        mutating func processInPlace(_ samples: inout [Float]) {
            for i in 0..<samples.count {
                let x = samples[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                samples[i] = y
            }
        }
    }

    struct BiquadHighShelf {
        private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        private var z1: Float = 0, z2: Float = 0

        init(f0: Double = 3200.0, gainDB: Double = 2.0, q: Double = 0.70710678, sampleRate: Double = 16000.0) {
            let a = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * Double.pi * f0 / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let alpha = sinW0 / (2.0 * q)
            let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha

            let a0 = (a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha
            b0 = Float((a * ((a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha)) / a0)
            b1 = Float((-2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)) / a0)
            b2 = Float((a * ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha)) / a0)
            a1 = Float((2.0 * ((a - 1.0) - (a + 1.0) * cosW0)) / a0)
            a2 = Float(((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha) / a0)
        }

        mutating func processInPlace(_ samples: inout [Float]) {
            for i in 0..<samples.count {
                let x = samples[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                samples[i] = y
            }
        }
    }

    private static func goertzelPowerAndRMS(
        samples: [Float],
        sampleRate: Double,
        targetFreq: Double
    ) -> (power: Double, rms: Double) {
        let n = samples.count
        guard n > 0 else { return (0, 0) }
        let w = 2.0 * Double.pi * targetFreq / sampleRate
        let coeff = 2.0 * cos(w)
        var s0: Double = 0
        var s1: Double = 0
        var s2: Double = 0
        for x in samples {
            s0 = Double(x) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2)
        let rms = sqrt(2.0 * power) / Double(n)
        return (power, rms)
    }

    static func processBuffer(
        _ samples: [Float],
        sampleRate: Double,
        trackLabel: String
    ) -> (cleaned: [Float], metrics: AudioTrackMetrics, findings: [AudioAnomalyFinding]) {
        if samples.isEmpty || sampleRate <= 0 {
            let metrics = AudioTrackMetrics(
                track: trackLabel,
                sampleRate: sampleRate > 0 ? sampleRate : 16000,
                durationSeconds: 0,
                speechRMSdBFSBefore: -100.0,
                speechRMSdBFSAfter: -100.0,
                peakdBFSBefore: -100.0,
                peakdBFSAfter: -100.0,
                noiseFloordBFSBefore: -100.0,
                noiseFloordBFSAfter: -100.0,
                clickCount: 0,
                clippedSamples: 0,
                dcOffset: 0,
                humFrequencyHz: nil
            )
            return ([], metrics, [])
        }

        var findings: [AudioAnomalyFinding] = []

        // 1. DC Offset
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        let dcOffset = Double(mean)
        if abs(mean) >= 0.0025 {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .dcOffset,
                detail: String(format: "DC offset of %+.4f centered", mean),
                fixed: true
            ))
        }

        // 2. Low-Frequency Rumble (<85 Hz)
        var lpf = BiquadLPF(cutoff: 85.0, sampleRate: sampleRate)
        let rumbleSamples = lpf.process(samples)
        var rumbleRMS: Float = 0
        vDSP_rmsqv(rumbleSamples, 1, &rumbleRMS, vDSP_Length(rumbleSamples.count))
        var totalRMS: Float = 0
        vDSP_rmsqv(samples, 1, &totalRMS, vDSP_Length(samples.count))
        let rumbleRMSdB = 20.0 * log10(max(Double(rumbleRMS), 1e-6))
        if rumbleRMSdB > -32.0 && Double(rumbleRMS) > 0.18 * Double(totalRMS) {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .lowFrequencyRumble,
                detail: String(format: "Low-frequency rumble (<85 Hz) at %.1f dBFS filtered", rumbleRMSdB),
                fixed: true
            ))
        }

        // 3. 50 Hz / 60 Hz Mains Hum
        var humFrequencyHz: Int? = nil
        let goertzelSampleCount = min(samples.count, Int(sampleRate * 30))
        if goertzelSampleCount >= max(64, Int(sampleRate * 0.5)) {
            let goertzelSamples = Array(samples[0..<goertzelSampleCount])
            let g50 = goertzelPowerAndRMS(samples: goertzelSamples, sampleRate: sampleRate, targetFreq: 50.0)
            let g42 = goertzelPowerAndRMS(samples: goertzelSamples, sampleRate: sampleRate, targetFreq: 42.0)
            let g58 = goertzelPowerAndRMS(samples: goertzelSamples, sampleRate: sampleRate, targetFreq: 58.0)
            let rms50dB = 20.0 * log10(max(g50.rms, 1e-6))
            let is50Hum = (g50.power / max(g42.power, 1e-12) >= 15.8) &&
                          (g50.power / max(g58.power, 1e-12) >= 15.8) &&
                          rms50dB > -50.0

            let g60 = goertzelPowerAndRMS(samples: goertzelSamples, sampleRate: sampleRate, targetFreq: 60.0)
            let g52 = goertzelPowerAndRMS(samples: goertzelSamples, sampleRate: sampleRate, targetFreq: 52.0)
            let g68 = goertzelPowerAndRMS(samples: goertzelSamples, sampleRate: sampleRate, targetFreq: 68.0)
            let rms60dB = 20.0 * log10(max(g60.rms, 1e-6))
            let is60Hum = (g60.power / max(g52.power, 1e-12) >= 15.8) &&
                          (g60.power / max(g68.power, 1e-12) >= 15.8) &&
                          rms60dB > -50.0

            if is50Hum && is60Hum {
                humFrequencyHz = g50.power >= g60.power ? 50 : 60
            } else if is50Hum {
                humFrequencyHz = 50
            } else if is60Hum {
                humFrequencyHz = 60
            }
        }
        if let hum = humFrequencyHz {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .mainsHum,
                detail: String(format: "%d Hz mains hum notch applied (narrowband tone detected)", hum),
                fixed: true
            ))
        }

        // 4. Dropout Gaps
        let minGapLen = max(32, Int(sampleRate * 0.005))
        var dropoutGaps: [(start: Int, end: Int)] = []
        var runStart: Int? = nil

        for i in 0..<samples.count {
            if abs(samples[i]) < 1e-6 {
                if runStart == nil {
                    runStart = i
                }
            } else {
                if let start = runStart {
                    let length = i - start
                    if length >= minGapLen {
                        let borderBefore = (start > 0 && abs(samples[start - 1]) >= 0.03)
                        let borderAfter = (abs(samples[i]) >= 0.03)
                        if borderBefore || borderAfter {
                            dropoutGaps.append((start: start, end: i))
                        }
                    }
                    runStart = nil
                }
            }
        }
        if let start = runStart {
            let length = samples.count - start
            if length >= minGapLen {
                let borderBefore = (start > 0 && abs(samples[start - 1]) >= 0.03)
                if borderBefore {
                    dropoutGaps.append((start: start, end: samples.count))
                }
            }
        }

        if !dropoutGaps.isEmpty {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .dropoutGaps,
                detail: String(format: "%d hard dropout gap%@ smoothed with cosine crossfades", dropoutGaps.count, dropoutGaps.count == 1 ? "" : "s"),
                fixed: true
            ))
        }

        // 5. Digital Clicks & Pops
        let blockLen = max(64, Int(sampleRate * 0.02))
        var clickSpans: [(start: Int, end: Int)] = []

        var blockStart = 1
        while blockStart < samples.count {
            let blockEnd = min(samples.count, blockStart + blockLen)
            var diffSum: Float = 0
            for idx in blockStart..<blockEnd {
                diffSum += abs(samples[idx] - samples[idx - 1])
            }
            let meanAbsDiff = diffSum / Float(blockEnd - blockStart)
            let spikeThreshold = max(0.10, meanAbsDiff * 8.5)
            let returnTolerance = max(0.04, meanAbsDiff * 2.5)

            var idx = blockStart
            while idx < blockEnd {
                let diff = abs(samples[idx] - samples[idx - 1])
                if diff > spikeThreshold {
                    let baseline = samples[idx - 1]
                    let maxLookahead = min(16, samples.count - 1 - idx)
                    var returnIndex: Int? = nil
                    for k in 1...maxLookahead {
                        if abs(samples[idx + k] - baseline) < returnTolerance {
                            returnIndex = idx + k
                            break
                        }
                    }
                    if let end = returnIndex {
                        clickSpans.append((start: idx, end: end))
                        idx = end + 1
                        continue
                    }
                }
                idx += 1
            }
            blockStart = blockEnd
        }

        let clickCount = clickSpans.count
        if clickCount > 0 {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .clicksAndPops,
                detail: String(format: "%d digital click%@ interpolated and suppressed", clickCount, clickCount == 1 ? "" : "s"),
                fixed: true
            ))
        }

        // 6. Digital Clipping
        var clippedSamples = 0
        for x in samples {
            if abs(x) >= 0.985 {
                clippedSamples += 1
            }
        }
        if clippedSamples >= 3 {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .clipping,
                detail: String(format: "%d clipped sample%@ reconstructed with headroom", clippedSamples, clippedSamples == 1 ? "" : "s"),
                fixed: true
            ))
        }

        // 7. Noise Floor & Active Speech Level
        let frameLen = max(64, Int(sampleRate * 0.02))
        let numFrames = samples.count / frameLen
        var analysisSamples = samples
        var analysisHPF = BiquadHPF(cutoff: 80.0, sampleRate: sampleRate)
        analysisHPF.processInPlace(&analysisSamples)
        if let humHz = humFrequencyHz {
            var notch = BiquadNotch(f0: Double(humHz), q: 30.0, sampleRate: sampleRate)
            notch.processInPlace(&analysisSamples)
        }
        var frameRMSs: [Double] = []
        frameRMSs.reserveCapacity(numFrames)
        for f in 0..<numFrames {
            let offset = f * frameLen
            var rms: Float = 0
            analysisSamples.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + offset, 1, &rms, vDSP_Length(frameLen))
            }
            frameRMSs.append(Double(rms))
        }

        let nonSilent = frameRMSs.filter { $0 > 1e-6 }.sorted()
        let noiseFloorLinear: Double
        if nonSilent.isEmpty {
            noiseFloorLinear = 1e-5
        } else {
            let p15Index = min(nonSilent.count - 1, max(0, Int(Double(nonSilent.count) * 0.15)))
            noiseFloorLinear = nonSilent[p15Index]
        }
        let noiseFloordBFSBefore = 20.0 * log10(max(noiseFloorLinear, 1e-6))

        let speechThreshold = max(noiseFloorLinear * 2.5, 0.0035)
        let speechFrames = frameRMSs.filter { $0 > speechThreshold }
        let speechRMSdBFSBefore: Double
        if speechFrames.isEmpty {
            speechRMSdBFSBefore = -100.0
        } else {
            let meanSq = speechFrames.reduce(0.0) { $0 + $1 * $1 } / Double(speechFrames.count)
            speechRMSdBFSBefore = 20.0 * log10(max(sqrt(meanSq), 1e-6))
        }

        var peakVal: Float = 0
        vDSP_maxmgv(samples, 1, &peakVal, vDSP_Length(samples.count))
        let peakdBFSBefore = 20.0 * log10(max(Double(peakVal), 1e-6))

        if noiseFloordBFSBefore > -46.0 {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .backgroundHiss,
                detail: String(format: "Noise floor elevated (%.1f dBFS) — downward expander applied", noiseFloordBFSBefore),
                fixed: true
            ))
        }
        if !speechFrames.isEmpty && speechRMSdBFSBefore < -24.0 {
            findings.append(AudioAnomalyFinding(
                track: trackLabel,
                kind: .lowLoudness,
                detail: String(format: "Speech loudness low (%.1f dBFS) — boosted toward studio target (-18 dBFS)", speechRMSdBFSBefore),
                fixed: true
            ))
        }

        // MARK: - Remediation DSP Chain
        var work = samples

        // 1. Remove DC offset
        var negMean = -mean
        vDSP_vsadd(work, 1, &negMean, &work, 1, vDSP_Length(work.count))

        // 2. De-Clipper
        var p = 0
        while p < work.count {
            if abs(work[p]) >= 0.985 {
                let sign = work[p] >= 0 ? Float(1.0) : Float(-1.0)
                var q = p
                while q + 1 < work.count && abs(work[q + 1]) >= 0.985 && ((work[q + 1] >= 0 ? 1 : -1) == (sign >= 0 ? 1 : -1)) {
                    q += 1
                }
                let length = q - p + 1
                if length >= 2 && length <= 24 && p > 0 && q + 1 < work.count {
                    let y0 = work[p - 1]
                    let y1 = work[q + 1]
                    let peakExtra = max(0.04, 0.015 * Float(length))
                    for k in p...q {
                        let t = Float(k - p + 1) / Float(length + 1)
                        let yLin = (1.0 - t) * y0 + t * y1
                        let arc = 4.0 * t * (1.0 - t) * peakExtra * sign
                        work[k] = yLin + arc
                    }
                }
                p = q + 1
            } else {
                p += 1
            }
        }
        if clippedSamples > 0 {
            var scale: Float = 0.85
            vDSP_vsmul(work, 1, &scale, &work, 1, vDSP_Length(work.count))
        }

        // 3. De-Clicker & Dropout Micro-Fades
        for span in clickSpans {
            let start = span.start
            let end = span.end
            if start > 0 && end < work.count {
                let y0 = work[start - 1]
                let y1 = work[end]
                let spanCount = end - start
                for idx in start..<end {
                    let t = Float(idx - start + 1) / Float(spanCount + 1)
                    work[idx] = (1.0 - t) * y0 + t * y1
                }
            }
        }

        let fadeFrames = max(1, Int(sampleRate * 0.004))
        for gap in dropoutGaps {
            if gap.start > 0 {
                let actualFade = min(fadeFrames, gap.start)
                let fadeStart = gap.start - actualFade
                for j in 0..<actualFade {
                    let t = Double(j + 1) / Double(actualFade)
                    let gain = Float(0.5 * (1.0 + cos(Double.pi * t)))
                    work[fadeStart + j] *= gain
                }
            }
            if gap.end < work.count {
                let actualFade = min(fadeFrames, work.count - gap.end)
                for j in 0..<actualFade {
                    let t = Double(j) / Double(actualFade)
                    let gain = Float(0.5 * (1.0 - cos(Double.pi * t)))
                    work[gap.end + j] *= gain
                }
            }
        }

        // 4. 80 Hz 2nd-Order Butterworth HPF
        var hpf = BiquadHPF(cutoff: 80.0, sampleRate: sampleRate)
        hpf.processInPlace(&work)

        // 5. Conditional 50/60 Hz Notch
        if let humHz = humFrequencyHz {
            var notch = BiquadNotch(f0: Double(humHz), q: 30.0, sampleRate: sampleRate)
            notch.processInPlace(&work)

            let harmonic = 2.0 * Double(humHz)
            if harmonic < 0.45 * sampleRate {
                var harmonicNotch = BiquadNotch(f0: harmonic, q: 20.0, sampleRate: sampleRate)
                harmonicNotch.processInPlace(&work)
            }
        }

        // 6. Smooth Musical Downward Noise Expander
        let expanderThreshold = max(Float(noiseFloorLinear * 2.2), 1e-4)
        let minGain: Float = 0.42
        let alphaAttack = Float(1.0 - exp(-1.0 / (sampleRate * 0.005)))
        let alphaRelease = Float(1.0 - exp(-1.0 / (sampleRate * 0.100)))

        var env: Float = expanderThreshold
        var currentGain: Float = 1.0

        for i in 0..<work.count {
            let ax = abs(work[i])
            if ax > env {
                env += alphaAttack * (ax - env)
            } else {
                env += alphaRelease * (ax - env)
            }

            let targetGain: Float
            if env >= expanderThreshold {
                targetGain = 1.0
            } else {
                let r = max(0, env / expanderThreshold)
                let s = r * r * (3.0 - 2.0 * r)
                targetGain = minGain + (1.0 - minGain) * s
            }

            if targetGain > currentGain {
                currentGain += alphaAttack * (targetGain - currentGain)
            } else {
                currentGain += alphaRelease * (targetGain - currentGain)
            }

            work[i] *= currentGain
        }

        // 7. Crisp Vocal Presence High-Shelf
        if sampleRate >= 12000.0 && 3200.0 < 0.45 * sampleRate {
            var shelf = BiquadHighShelf(f0: 3200.0, gainDB: 2.0, q: 0.70710678, sampleRate: sampleRate)
            shelf.processInPlace(&work)
        }

        // 8. Active-Speech Loudness Normalization + Soft True-Peak Limiter
        if numFrames > 0 {
            var speechRMSValues: [Double] = []
            for f in 0..<numFrames {
                let offset = f * frameLen
                var rms: Float = 0
                work.withUnsafeBufferPointer { ptr in
                    vDSP_rmsqv(ptr.baseAddress! + offset, 1, &rms, vDSP_Length(frameLen))
                }
                if Double(rms) > speechThreshold {
                    speechRMSValues.append(Double(rms))
                }
            }

            if !speechRMSValues.isEmpty {
                let meanSq = speechRMSValues.reduce(0.0) { $0 + $1 * $1 } / Double(speechRMSValues.count)
                let currentSpeechRMS = sqrt(meanSq)
                let currentSpeechDB = 20.0 * log10(max(currentSpeechRMS, 1e-6))
                let gainDB = min(14.0, max(-6.0, -18.0 - currentSpeechDB))
                var linearGain = Float(pow(10.0, gainDB / 20.0))
                vDSP_vsmul(work, 1, &linearGain, &work, 1, vDSP_Length(work.count))
            }
        }

        for i in 0..<work.count {
            let x = work[i]
            let ax = abs(x)
            if ax > 0.70 {
                let excess = Double(ax - 0.70)
                let limited = 0.70 + 0.191 * tanh(excess / 0.191)
                work[i] = Float(x >= 0 ? limited : -limited)
            }
        }

        // 9. After Metrics
        var afterFrameRMSs: [Double] = []
        afterFrameRMSs.reserveCapacity(numFrames)
        for f in 0..<numFrames {
            let offset = f * frameLen
            var rms: Float = 0
            work.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + offset, 1, &rms, vDSP_Length(frameLen))
            }
            afterFrameRMSs.append(Double(rms))
        }

        let nonSilentAfter = afterFrameRMSs.filter { $0 > 1e-6 }.sorted()
        let noiseFloordBFSAfter: Double
        let noiseFloorLinearAfter: Double
        if nonSilentAfter.isEmpty {
            noiseFloorLinearAfter = 1e-5
            noiseFloordBFSAfter = -100.0
        } else {
            let p15Index = min(nonSilentAfter.count - 1, max(0, Int(Double(nonSilentAfter.count) * 0.15)))
            noiseFloorLinearAfter = nonSilentAfter[p15Index]
            noiseFloordBFSAfter = 20.0 * log10(max(noiseFloorLinearAfter, 1e-6))
        }

        let speechThresholdAfter = max(noiseFloorLinearAfter * 2.5, 0.0035)
        let speechFramesAfter = afterFrameRMSs.filter { $0 > speechThresholdAfter }
        let speechRMSdBFSAfter: Double
        if speechFramesAfter.isEmpty {
            speechRMSdBFSAfter = -100.0
        } else {
            let meanSq = speechFramesAfter.reduce(0.0) { $0 + $1 * $1 } / Double(speechFramesAfter.count)
            speechRMSdBFSAfter = 20.0 * log10(max(sqrt(meanSq), 1e-6))
        }

        var peakValAfter: Float = 0
        vDSP_maxmgv(work, 1, &peakValAfter, vDSP_Length(work.count))
        let peakdBFSAfter = 20.0 * log10(max(Double(peakValAfter), 1e-6))

        let metrics = AudioTrackMetrics(
            track: trackLabel,
            sampleRate: sampleRate,
            durationSeconds: Double(samples.count) / sampleRate,
            speechRMSdBFSBefore: speechRMSdBFSBefore,
            speechRMSdBFSAfter: speechRMSdBFSAfter,
            peakdBFSBefore: peakdBFSBefore,
            peakdBFSAfter: peakdBFSAfter,
            noiseFloordBFSBefore: noiseFloordBFSBefore,
            noiseFloordBFSAfter: noiseFloordBFSAfter,
            clickCount: clickCount,
            clippedSamples: clippedSamples,
            dcOffset: dcOffset,
            humFrequencyHz: humFrequencyHz
        )

        return (work, metrics, findings)
    }

    private static func loadAudioFile(path: String) throws -> (samples: [Float], sampleRate: Double) {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = file.length
        guard totalFrames > 0 else {
            return ([], sampleRate)
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(totalFrames))
        let chunkSize: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw NSError(
                domain: "AudioQualityCleaner",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"]
            )
        }

        while file.framePosition < totalFrames {
            let framesToRead = min(chunkSize, AVAudioFrameCount(totalFrames - file.framePosition))
            try file.read(into: buffer, frameCount: framesToRead)
            let count = Int(buffer.frameLength)
            if count == 0 { break }

            guard let channelData = buffer.floatChannelData else {
                throw NSError(
                    domain: "AudioQualityCleaner",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing float channel data"]
                )
            }

            if channelCount == 1 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
            } else {
                let startCount = samples.count
                samples.append(contentsOf: repeatElement(0, count: count))
                for i in 0..<count {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += channelData[c][i]
                    }
                    samples[startCount + i] = sum / Float(channelCount)
                }
            }
        }
        return (samples, sampleRate)
    }

    private static func writeAudioFile(samples: [Float], sampleRate: Double, outPath: String) throws {
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioQualityCleaner",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create mono audio format"]
            )
        }

        let outFile = try AVAudioFile(forWriting: outURL, settings: monoFormat.settings)
        let chunkSize: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkSize) else {
            throw NSError(
                domain: "AudioQualityCleaner",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output PCM buffer"]
            )
        }

        var offset = 0
        let total = samples.count
        while offset < total {
            let count = min(Int(chunkSize), total - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { ptr in
                _ = memcpy(buffer.floatChannelData![0], ptr.baseAddress! + offset, count * MemoryLayout<Float>.size)
            }
            try outFile.write(from: buffer)
            offset += count
        }
    }

    static func cleanMeetingTracks(
        systemPath: String?,
        micPath: String?
    ) throws -> (cleanedSystemPath: String?, cleanedMicPath: String?, report: AudioQualityReport) {
        let startTime = CFAbsoluteTimeGetCurrent()
        var tracks: [AudioTrackMetrics] = []
        var anomalies: [AudioAnomalyFinding] = []

        var cleanedSystemPath: String? = nil
        if let sysPath = systemPath,
           !sysPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: sysPath) {
            let (rawSamples, sampleRate) = try loadAudioFile(path: sysPath)
            let (cleanedSamples, sysMetrics, sysFindings) = processBuffer(
                rawSamples,
                sampleRate: sampleRate,
                trackLabel: "System Audio"
            )
            let outPath = cleanedPath(for: sysPath)
            try writeAudioFile(samples: cleanedSamples, sampleRate: sampleRate, outPath: outPath)
            cleanedSystemPath = outPath
            tracks.append(sysMetrics)
            anomalies.append(contentsOf: sysFindings)
        }

        var cleanedMicPath: String? = nil
        if let mPath = micPath,
           !mPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: mPath) {
            let (rawSamples, sampleRate) = try loadAudioFile(path: mPath)
            let (cleanedSamples, micMetrics, micFindings) = processBuffer(
                rawSamples,
                sampleRate: sampleRate,
                trackLabel: "Microphone Audio"
            )
            let outPath = cleanedPath(for: mPath)
            try writeAudioFile(samples: cleanedSamples, sampleRate: sampleRate, outPath: outPath)
            cleanedMicPath = outPath
            tracks.append(micMetrics)
            anomalies.append(contentsOf: micFindings)
        }

        let elapsed = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
        let report = AudioQualityReport(
            processedAt: Date(),
            tracks: tracks,
            anomalies: anomalies,
            elapsedMs: elapsed
        )

        return (cleanedSystemPath, cleanedMicPath, report)
    }
}
