//
//  BackgroundKeeper.swift
//  Keeps the process resident in the background so the touch service can keep
//  observing and injecting. iOS aggressively terminates background apps, so we
//  combine the most reliable keep-alive mechanisms:
//    1. Continuous location updates (CLLocationManager, frequent, always auth).
//    2. A silent looping audio playback (AVAudioSession .playback) which keeps
//       the process scheduled by the audio subsystem.
//    3. A watchdog that re-asserts both mechanisms if either stops (the system
//       can silently suspend background audio or throttle location).
//    4. A background task when the app backgrounds, to buy time.
//    5. Optional: prevent device sleep (isIdleTimerDisabled) — a sleeping
//       device suspends everything, so this is the strongest single lever.
//

import Foundation
import UIKit
import CoreLocation
import AVFoundation
import Combine

final class BackgroundKeeper: NSObject, CLLocationManagerDelegate, ObservableObject {
    static let shared = BackgroundKeeper()

    let location = CLLocationManager()
    private var audioPlayer: AVAudioPlayer?
    private var watchdog: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastLocationUpdate: Date = .distantPast

    private(set) var isRunning = false

    // Reachability of the keep-alive mechanisms (for the UI).
    @Published var locationActive = false
    @Published var audioActive = false
    @Published var watchdogBeats = 0
    @Published var locationDenied = false
    @Published var inBackground = false
    @Published var preventSleep = false {
        didSet {
            guard preventSleep != oldValue else { return }
            UIApplication.shared.isIdleTimerDisabled = preventSleep
        }
    }

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyReduced
        location.distanceFilter = 5
        if #available(iOS 13.0, *) {
            location.allowsBackgroundLocationUpdates = true
            location.pausesLocationUpdatesAutomatically = false
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startLocation()
        startAudio()
        startWatchdog()
        print("[BackgroundKeeper] Started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        location.stopUpdatingLocation()
        locationActive = false
        stopAudio()
        stopWatchdog()
        endBackgroundTask()
        UIApplication.shared.isIdleTimerDisabled = false
        print("[BackgroundKeeper] Stopped")
    }

    /// Re-assert everything (call on didBecomeActive / foreground).
    func reassert() {
        guard isRunning else { return }
        startAudio()
        startLocation()
    }

    func appDidBecomeActive() {
        inBackground = false
        reassert()
    }

    func appDidEnterBackground() {
        guard isRunning else { return }
        inBackground = true
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            self.endBackgroundTask()
        }
        // Give the audio session one more nudge while we still have time.
        startAudio()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Location

    private func startLocation() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestAlwaysAuthorization()
            location.startUpdatingLocation()
        case .authorizedAlways, .authorizedWhenInUse:
            location.startUpdatingLocation()
        case .denied, .restricted:
            locationDenied = true
            locationActive = false
            return
        @unknown default:
            location.startUpdatingLocation()
        }
        locationActive = true
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't actually need the location; the updates keep us alive.
        lastLocationUpdate = Date()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("[BackgroundKeeper] Location auth: \(status.rawValue)")
        locationDenied = (status == .denied || status == .restricted)
        if !locationDenied {
            startLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[BackgroundKeeper] Location error: \(error.localizedDescription)")
    }

    /// Open the user's Settings page for this app (when location is denied).
    func openAppSettings() {
        if let url = URL(string: "App-prefs:root=USER") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Audio (silent loop)

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session setActive(true)
        } catch {
            print("[BackgroundKeeper] Audio session error: \(error)")
            audioActive = false
            return
        }
        // (Re)start the looping silent player.
        if audioPlayer == nil || !audioPlayer!.isPlaying {
            do {
                let player = try AVAudioPlayer(data: silentWAVData())
                player.numberOfLoops = -1   // infinite
                player.volume = 0.01        // near-silent but "playing"
                player.prepareToPlay()
                player.play()
                audioPlayer = player
            } catch {
                print("[BackgroundKeeper] Audio player error: \(error)")
                audioActive = false
                return
            }
        }
        audioActive = true
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioActive = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(t, for: .common)
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        guard isRunning else { return }
        watchdogBeats += 1
        // Audio: if the player died (system suspended it), restart it.
        if audioActive, audioPlayer == nil || !audioPlayer!.isPlaying {
            print("[BackgroundKeeper] Watchdog: audio died, restarting")
            startAudio()
        }
        // Location: if no update for 90s, nudge it again.
        if Date().timeIntervalSince(lastLocationUpdate) > 90 {
            print("[BackgroundKeeper] Watchdog: location stale, restarting")
            location.stopUpdatingLocation()
            startLocation()
        }
    }

    // MARK: - Silent WAV (generated in-memory)

    private func silentWAVData() -> Data {
        let sampleRate = 8000
        let numSamples = 8000   // 1 second
        let numChannels = 1
        let bitsPerSample = 16
        let dataBytes = numSamples * numChannels * (bitsPerSample / 8)
        var wav = Data()
        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(UInt32(36 + dataBytes).littleEndianData)
        wav.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(UInt32(16).littleEndianData)
        wav.append(UInt16(1).littleEndianData)          // PCM
        wav.append(UInt16(numChannels).littleEndianData)
        wav.append(UInt32(sampleRate).littleEndianData)
        wav.append(UInt32(sampleRate * numChannels * (bitsPerSample / 8)).littleEndianData)
        wav.append(UInt16(numChannels * (bitsPerSample / 8)).littleEndianData)
        wav.append(UInt16(bitsPerSample).littleEndianData)
        // data chunk
        wav.append("data".data(using: .ascii)!)
        wav.append(UInt32(dataBytes).littleEndianData)
        wav.append(Data(count: dataBytes))             // silence
        return wav
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes { Data($0.reversed()) }
    }
}
private extension UInt16 {
    var littleEndianData: Data {
        withUnsafeBytes { Data($0.reversed()) }
    }
}
