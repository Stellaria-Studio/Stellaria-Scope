import CoreGraphics
import CoreVideo
import Darwin
import Foundation

final class DisplayRefreshCollector {
    private var displayLink: CVDisplayLink?
    private let lock = NSLock()
    private var lastHostTime: UInt64 = 0
    private var intervals: [Double] = []
    private var timebase = mach_timebase_info_data_t()
    private var isDisplayLinkRunning = false
    private var lastBurstStarted = Date.distantPast
    private var lastBurstCompleted = Date.distantPast

    init() {
        mach_timebase_info(&timebase)
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link) == kCVReturnSuccess, let link {
            displayLink = link
            let opaqueSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            CVDisplayLinkSetOutputCallback(link, { _, now, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnSuccess }
                let collector = Unmanaged<DisplayRefreshCollector>.fromOpaque(userInfo).takeUnretainedValue()
                collector.record(hostTime: now.pointee.hostTime)
                return kCVReturnSuccess
            }, opaqueSelf)
        }
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    func sample(active: Bool = true) -> DisplayRefreshSnapshot {
        if active {
            updateMeasurementState()
        } else {
            stopMeasurement()
        }
        let measured = measuredHz()
        let displayID = CGMainDisplayID()
        let mode = CGDisplayCopyDisplayMode(displayID)
        let nominal = displayLink.flatMap { link -> Double? in
            let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
            guard period.timeValue > 0 else { return nil }
            return Double(period.timeScale) / Double(period.timeValue)
        }
        let actual = displayLink.flatMap { link -> Double? in
            let period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
            return period > 0 ? 1.0 / period : nil
        }
        return DisplayRefreshSnapshot(
            measuredHz: measured,
            nominalHz: nominal,
            actualHz: actual,
            modeHz: mode?.refreshRate,
            pixelWidth: mode.map { $0.pixelWidth } ?? 0,
            pixelHeight: mode.map { $0.pixelHeight } ?? 0,
            logicalWidth: mode.map { $0.width } ?? 0,
            logicalHeight: mode.map { $0.height } ?? 0,
            timestamp: Date()
        )
    }

    private func updateMeasurementState() {
        guard let displayLink else { return }
        let now = Date()
        lock.lock()
        let shouldStart = !isDisplayLinkRunning
            && (intervals.isEmpty || now.timeIntervalSince(lastBurstCompleted) > 15.0)
        let shouldStop = isDisplayLinkRunning
            && (intervals.count >= 45 || now.timeIntervalSince(lastBurstStarted) > 2.5)
        lock.unlock()

        if shouldStart {
            lock.lock()
            intervals.removeAll(keepingCapacity: true)
            lastHostTime = 0
            lastBurstStarted = now
            isDisplayLinkRunning = true
            lock.unlock()
            CVDisplayLinkStart(displayLink)
        } else if shouldStop {
            CVDisplayLinkStop(displayLink)
            lock.lock()
            isDisplayLinkRunning = false
            lastBurstCompleted = now
            lock.unlock()
        }
    }

    private func stopMeasurement() {
        guard let displayLink else { return }
        lock.lock()
        let running = isDisplayLinkRunning
        isDisplayLinkRunning = false
        lastBurstCompleted = Date()
        lock.unlock()
        if running {
            CVDisplayLinkStop(displayLink)
        }
    }

    private func record(hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if lastHostTime > 0, hostTime > lastHostTime {
            let deltaTicks = hostTime - lastHostTime
            let nanos = Double(deltaTicks) * Double(timebase.numer) / Double(timebase.denom)
            let seconds = nanos / 1_000_000_000.0
            if seconds > 0.001, seconds < 0.2 {
                intervals.append(seconds)
                if intervals.count > 90 {
                    intervals.removeFirst(intervals.count - 90)
                }
            }
        }
        lastHostTime = hostTime
    }

    private func measuredHz() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !intervals.isEmpty else { return nil }
        let recent = intervals.suffix(45)
        let average = recent.reduce(0, +) / Double(recent.count)
        return average > 0 ? 1.0 / average : nil
    }
}
