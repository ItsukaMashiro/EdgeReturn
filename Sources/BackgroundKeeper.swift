//
//  BackgroundKeeper.swift
//  Keeps the process resident in the background so the touch service can keep
//  observing and injecting. iOS aggressively terminates background apps, so we
//  combine the two most reliable keep-alive mechanisms:
//    1. Continuous location updates (CLLocationManager, frequent).
//    2. A silent audio playback session (AVAudioSession, .playback + a looping
//       silent buffer) which keeps the process in the foreground of the
//       audio subsystem.
//
//  Together these make the app very hard for iOS to kill while it is "active".
//

import Foundation
import CoreLocation
import AVFoundation

final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()

    let location = CLLocationManager()
    private var audioPlayer: AVAudioPlayer?
    private var audioTimer: Timer?
    private(set) var isRunning = false

    // Reachability of the keep-alive mechanisms (for the UI).
    var locationActive: Bool = false
    var audioActive: Bool = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyReduced
        location.distanceFilter = 5
        // Frequent updates keep the process alive.
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
        print("[BackgroundKeeper] Started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        location.stopUpdatingLocation()
        locationActive = false
        stopAudio()
        print("[BackgroundKeeper] Stopped")
    }

    // MARK: - Location

    private func startLocation() {
        #if targetEnvironment(simulator)
        location.requestAlwaysAuthorization()
        #else
        location.requestAlwaysAuthorization()
        #endif
        location.startUpdatingLocation()
        locationActive = true
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't actually need the location; the updates keep us alive.
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("[BackgroundKeeper] Location auth: \(status.rawValue)")
    }

    // MARK: - Audio (silent loop)

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[BackgroundKeeper] Audio session error: \(error)")
            return
        }
        audioActive = true
        // Loop a silent buffer to keep the audio session "playing".
        playSilentLoop()
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioTimer?.invalidate()
        audioTimer = nil
        audioActive = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Build a short silent PCM buffer and loop it.
    private func playSilentLoop() {
        let sampleRate = 44100.0
        let seconds = 2.0
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        // Zero the samples (silent).
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memset(data[channel], 0, Int(frameCount) * MemoryLayout<Float32>.size)
            }
        }
        do {
            let player = try AVAudioPlayer(data: silentWAVData())
            player.numberOfLoops = -1   // infinite
            player.volume = 0.01        // near-silent but "playing"
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            print("[BackgroundKeeper] Audio player error: \(error)")
        }
    }

    /// A tiny silent WAV file (generated in-memory) for the looping player.
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
