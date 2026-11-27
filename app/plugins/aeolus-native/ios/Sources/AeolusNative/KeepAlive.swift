import AVFoundation
import Foundation
import UIKit

/// Keeps Aeolus running while it is minimized, so Background Sync can check for payments every
/// 60 s like Android's foreground service. iOS only lets an app keep running in the background
/// while it plays audio (UIBackgroundModes "audio"), so this plays silence, mixed with whatever
/// else is playing (no Now Playing controls, no effect on music or calls).
///
/// Runs only while Background Sync and Payment Alerts are on and the app is in the background;
/// stops the moment the app comes back. A swipe-away ends the process: after that only iOS's own
/// occasional wake-ups (BGTaskScheduler) remain. Fine for a sideloaded app; App Store review
/// would refuse background audio used this way.
final class KeepAlive: NSObject {
    static let shared = KeepAlive()

    static let firstRun: TimeInterval = 20
    static let interval: TimeInterval = 60
    static let runBudget: TimeInterval = 50

    private let q = DispatchQueue(label: "aeolus.keepalive")
    private var player: AVAudioPlayer?      // q only
    private var timer: DispatchSourceTimer? // q only
    private var on = false                  // q only
    private let flag = NSLock()
    private var runningFlag = false

    /// For the debug log's state line.
    var isRunning: Bool { flag.lock(); defer { flag.unlock() }; return runningFlag }

    private override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interrupted(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaReset),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    /// The app went to the background with Background Sync on.
    func start() {
        // A few seconds of guaranteed run time to get the audio going before iOS suspends us.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "aeolus.keepalive") {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        q.async { [self] in
            defer { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(bgTask) } }
            guard !on else { return }
            guard play() else {
                BgLog.add("could not keep running in the background (audio refused) · iOS wake-ups only")
                return
            }
            on = true
            setRunning(true)
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + Self.firstRun, repeating: Self.interval, leeway: .seconds(5))
            t.setEventHandler { AeolusBackground.keepAliveRun(budget: KeepAlive.runBudget) }
            t.resume()
            timer = t
            BgLog.add("app minimized · keeping Background Sync running (check every \(Int(Self.interval)) s)", dedupe: true)
        }
    }

    /// The app is back in front, or Background Sync was switched off / the wallet deleted.
    func stop(reason: String? = nil) {
        q.async { [self] in
            guard on else { return }
            on = false
            setRunning(false)
            timer?.cancel()
            timer = nil
            player?.stop()
            player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            if let reason { BgLog.add(reason, dedupe: true) }
        }
    }

    // MARK: - silent audio (q only)

    private func play() -> Bool {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silentWav())
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                player = p
            }
            return player?.play() ?? false
        } catch {
            return false
        }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        q.async { [self] in
            guard on else { return }
            if !play() { BgLog.add("background audio did not resume after an interruption", dedupe: true) }
        }
    }

    @objc private func mediaReset() {
        q.async { [self] in
            guard on else { return }
            player = nil
            if !play() { BgLog.add("background audio did not restart after an audio reset", dedupe: true) }
        }
    }

    private func setRunning(_ v: Bool) { flag.lock(); runningFlag = v; flag.unlock() }

    /// 1 s of 8 kHz mono 16-bit silence as a WAV file.
    private static func silentWav() -> Data {
        let rate = 8000, samples = rate, dataLen = samples * 2
        var d = Data()
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        tag("RIFF"); u32(36 + dataLen); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        tag("data"); u32(dataLen)
        d.append(Data(count: dataLen))
        return d
    }
}
