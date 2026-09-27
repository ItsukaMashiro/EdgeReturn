//
//  TouchService.swift
//  Android-style right-edge swipe-back engine.
//
//  Two backends feed one gesture model:
//
//  1. System-wide: a private IOKit HID event-system client observes raw
//     digitizer events from every app (works even while we sit in the
//     background). All private symbols are resolved with dlopen/dlsym at
//     runtime; if a future iOS release removes them, `hidAvailable` is
//     false and the rest of the app degrades gracefully.
//
//  2. Foreground fallback: a UIScreenEdgePanGestureRecognizer on the app's
//     own window (right edge), active only when the private API is
//     unavailable, so the gesture still works inside this app.
//
//  The gesture model mirrors Android's edge navigation:
//
//  - a touch that starts within `edgeThreshold` of the right edge is "in
//    the edge" (a light haptic tick, like Android's drag indicator
//    appearing);
//  - moving horizontally past `engageDistance` engages the gesture (a
//    second, firmer tick);
//  - releasing past `completeDistance`, or flicking at or above
//    `flickVelocity`, completes it. The synthetic swipe we inject is
//    PACED TO THE USER'S ACTUAL SWIPE TIME (clamped 0.12s...0.4s), so the
//    native back animation follows the pace of your finger — the core of
//    the Android feel;
//  - a long-press in the edge zone (optional, `longPressEnabled`) injects
//    a bottom-edge swipe (home / app switcher), like Android's
//    long-press-edge;
//  - releasing short of the thresholds cancels (indicator fades out),
//    exactly like Android's cancelable drag.
//

import Foundation
import CoreGraphics
import UIKit
import QuartzCore
import CoreHaptics

final class TouchService: NSObject, ObservableObject {

    // MARK: - Published state (UI)

    @Published var isObserving = false
    @Published var hidAvailable = false
    @Published var hidDetail = "not loaded"
    @Published var lastBackAt: Date?
    @Published var lastHomeAt: Date?
    @Published var edgeTouchActive = false
    @Published var edgeTouchProgress: Double = 0
    @Published private(set) var eventLog: [String] = []

    // MARK: - Tuning (persisted by the UI layer)

    /// Distance from the right edge within which a touch starts a swipe (pt).
    var edgeThreshold: Float = 28
    /// Horizontal travel (pt) at which the gesture engages (haptic tick).
    var engageDistance: Float = 35
    /// Horizontal travel (pt) past which a release completes the back.
    var completeDistance: Float = 55
    /// Horizontal velocity (pt/s) that completes the back even short of the
    /// distance threshold (a flick).
    var flickVelocity: Float = 500
    /// Maximum vertical drift (pt) before the gesture is rejected.
    var maxVerticalDrift: Float = 45
    /// How long a touch must stay in the edge zone to count as a long-press (s).
    var longPressDuration: TimeInterval = 0.5
    /// Maximum drift (pt) allowed while a long-press is held.
    var longPressMaxDrift: Float = 12
    /// Cooldown after a successful trigger (s) to avoid double-firing.
    var cooldown: TimeInterval = 0.5

    var hapticsEnabled = true
    var backEnabled = true
    var longPressEnabled = false
    var preventSleep = false

    // MARK: - Private

    private var client: IOHIDEventSystemClientRef?
    private var dylib: UnsafeMutableRawPointer?
    private var fallbackRecognizer: UIScreenEdgePanGestureRecognizer?
    private var longPressTimer: Timer?

    private typealias CreateFn = @convention(c) (CFAllocator?, UnsafeMutablePointer<IOHIDEventSystemClientRef?>) -> Int32
    private typealias SetDispatchFn = @convention(c) (IOHIDEventSystemClientRef?, @convention(c) (UnsafeMutableRawPointer?, IOHIDEventRef?) -> Void, UnsafeMutableRawPointer?) -> Int32
    private typealias DispatchEventFn = @convention(c) (IOHIDEventSystemClientRef?, IOHIDEventRef?) -> Int32
    private typealias DigitizerFn = @convention(c) (CFAllocator?, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, Float32, Float32, Float32, Float32, UInt32) -> IOHIDEventRef?
    private typealias GetEventTypeFn = @convention(c) (IOHIDEventRef?) -> UInt32
    private typealias GetFloatFn = @convention(c) (IOHIDEventRef?, Int32) -> Float32
    private typealias GetIntFn = @convention(c) (IOHIDEventRef?, Int32) -> Int32

    private var fnCreate: CreateFn?
    private var fnSetDispatch: SetDispatchFn?
    private var fnDispatchEvent: DispatchEventFn?
    private var fnDigitizer: DigitizerFn?
    private var fnGetEventType: GetEventTypeFn?
    private var fnGetFloat: GetFloatFn?
    private var fnGetInt: GetIntFn?

    private var lastTriggerAt: Date = .distantPast
    private var hapticEngine: CHHapticEngine?

    /// One in-flight touch, keyed by the event's digitizer index (stable per
    /// finger, unlike a synthetic id we would have to invent ourselves).
    private struct TouchTrack {
        var index: Int
        var startX: Float
        var startY: Float
        var lastX: Float
        var lastY: Float
        var startTime: TimeInterval
        var engaged: Bool
        var triggered: Bool
        var longPressFired: Bool
    }
    private var activeTouches: [Int: TouchTrack] = [:]

    /// Private digitizer sub-type values (not in the public headers).
    private let kSubBegin: UInt32 = 1
    private let kSubMove: UInt32 = 3
    private let kSubEnd: UInt32 = 2
    private let kDigitizerFingerType: UInt32 = 13 // kIOHIDEventDigitizerTypeFinger
    private let kEventDigitizerType: UInt32 = 30  // IOHIDEventTypeDigitizer

    static let shared = TouchService()

    // MARK: - Setup

    /// Load IOKit, resolve the private symbols, start observing. When the
    /// private API is unavailable, falls back to a right-edge pan on our own
    /// window so the gesture still works inside this app.
    @discardableResult
    func startObserving() -> Bool {
        if client != nil { return true }
        loadSymbols()
        if hidAvailable, let create = fnCreate, let setDispatch = fnSetDispatch {
            var c: IOHIDEventSystemClientRef?
            let kr = create(nil, &c)
            if kr == 0, let client = c {
                let kr2 = setDispatch(client, { ctx, event in
                    guard let ctx = ctx, let event = event else { return }
                    let service = Unmanaged<TouchService>.fromOpaque(ctx).takeUnretainedValue()
                    service.handleEvent(event)
                }, Unmanaged.passUnretained(self).toOpaque())
                if kr2 == 0 {
                    self.client = client
                    isObserving = true
                    hidDetail = "live (system-wide)"
                    startLongPressTimer()
                    logEvent("HID observer live (system-wide)")
                    return true
                }
                hidDetail = "set dispatch failed (kr=\(kr2))"
            } else {
                hidDetail = "client create failed (kr=\(kr))"
            }
        } else {
            hidDetail = "symbols missing"
        }
        // Fallback: foreground-only edge pan on our own window.
        setupFallbackRecognizer()
        return false
    }

    private func loadSymbols() {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        dylib = dlopen(path, RTLD_LAZY)
        guard dylib != nil else {
            hidDetail = "dlopen failed"
            return
        }
        fnCreate = symbol("IOHIDEventSystemClientCreate")
        fnSetDispatch = symbol("IOHIDEventSystemClientSetEventDispatchFunction")
        fnDispatchEvent = symbol("IOHIDEventSystemClientDispatchEvent")
        fnDigitizer = symbol("IOHIDEventCreateDigitizerEvent")
        fnGetEventType = symbol("IOHIDEventGetEventType")
        fnGetFloat = symbol("IOHIDEventGetFloatValue")
        fnGetInt = symbol("IOHIDEventGetIntegerValue")
        hidAvailable = fnCreate != nil && fnSetDispatch != nil && fnDispatchEvent != nil
            && fnDigitizer != nil && fnGetEventType != nil && fnGetFloat != nil && fnGetInt != nil
        hidDetail = hidAvailable ? "symbols resolved" : "symbols missing"
    }

    private func symbol<T>(_ name: String) -> T? {
        guard let handle = dlsym(dylib, name) else { return nil }
        return unsafeBitCast(handle, to: T.self)
    }

    private func setupFallbackRecognizer() {
        guard fallbackRecognizer == nil else { return }
        let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleFallbackPan(_:)))
        recognizer.edges = .right
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.keyWindow else { return }
            window.addGestureRecognizer(recognizer)
        }
        fallbackRecognizer = recognizer
        if isObserving == false {
            isObserving = true
            hidDetail = "fallback (in-app only)"
        }
        logEvent("HID unavailable — in-app fallback active")
    }

    // MARK: - Unified gesture model

    private func beginTouch(index: Int, x: Float, y: Float) {
        let now = CACurrentMediaTime()
        let inEdge = x >= Float(UIScreen.main.bounds.width) - edgeThreshold
        activeTouches[index] = TouchTrack(
            index: index, startX: x, startY: y, lastX: x, lastY: y,
            startTime: now, engaged: false, triggered: false, longPressFired: false
        )
        if inEdge {
            engageTick()
            setEdgeIndicator(active: true, progress: 0)
            logEvent("edge begin x=\(Int(x)) y=\(Int(y))")
        }
    }

    private func moveTouch(index: Int, x: Float, y: Float) {
        guard var track = activeTouches[index], !track.triggered else { return }
        let inEdge = track.startX >= Float(UIScreen.main.bounds.width) - edgeThreshold
        guard inEdge else { return }
        track.lastX = x
        track.lastY = y
        activeTouches[index] = track
        checkEngage(track)
        checkLongPress(track)
        // Grow the edge indicator with the swipe (Android's drag indicator).
        let dx = x - track.startX
        let progress = Double(min(max(-dx / completeDistance, 0), 1))
        setEdgeIndicator(active: true, progress: progress)
    }

    private func endTouch(index: Int) {
        guard let track = activeTouches[index] else { return }
        activeTouches.removeValue(forKey: index)
        setEdgeIndicator(active: false, progress: 0)
        guard !track.triggered else { return }
        evaluateRelease(track)
    }

    /// Android's engagement: crossing the engage distance gives a firmer tick
    /// (the moment Android's drag indicator "locks in").
    private func checkEngage(_ track: TouchTrack) {
        guard !track.engaged else { return }
        let dx = track.lastX - track.startX
        guard dx < 0, -dx >= engageDistance, abs(track.lastY - track.startY) <= maxVerticalDrift else { return }
        if var t = activeTouches[track.index] {
            t.engaged = true
            activeTouches[track.index] = t
        }
        engageTick()
        logEvent("edge engaged")
    }

    /// Android's long-press-edge: hold in the edge zone, minimal drift.
    private func checkLongPress(_ track: TouchTrack) {
        guard longPressEnabled, !track.longPressFired, !track.triggered else { return }
        let held = CACurrentMediaTime() - track.startTime
        let drift = hypot(CGFloat(track.lastX - track.startX), CGFloat(track.lastY - track.startY))
        guard held >= longPressDuration, drift <= CGFloat(longPressMaxDrift) else { return }
        if var t = activeTouches[track.index] {
            t.longPressFired = true
            t.triggered = true
            activeTouches[track.index] = t
        }
        activeTouches.removeValue(forKey: track.index)
        fireHome()
    }

    /// Android's completion: release past the distance threshold, or a fast
    /// flick. The injected swipe is paced to the user's actual swipe time.
    private func evaluateRelease(_ track: TouchTrack) {
        guard backEnabled else { return }
        let dx = track.lastX - track.startX
        let dy = track.lastY - track.startY
        guard dx < 0 else { return }
        guard abs(dy) <= maxVerticalDrift else { return }
        let elapsed = max(CACurrentMediaTime() - track.startTime, 0.001)
        let velocity = -dx / Float(elapsed)
        let byDistance = -dx >= completeDistance
        let byFlick = velocity >= flickVelocity
        guard byDistance || byFlick else {
            logEvent("edge cancelled (dist \(Int(-dx))pt, vel \(Int(velocity))pt/s)")
            return
        }
        guard Date().timeIntervalSince(lastTriggerAt) >= cooldown else { return }
        lastTriggerAt = Date()
        // Pace the synthetic swipe to the user's actual swipe time (Android
        // feel: the native animation follows the pace of your finger).
        let duration = min(max(elapsed, 0.12), 0.4)
        fireBack(duration: duration)
    }

    // MARK: - Triggers

    private func fireBack(duration: CFTimeInterval) {
        injectSwipe(edge: .left, duration: duration)
        lastBackAt = Date()
        logEvent("back triggered (paced \(Int(duration * 1000))ms)")
        successTick()
    }

    private func fireHome() {
        injectSwipe(edge: .bottom, duration: 0.25)
        lastHomeAt = Date()
        logEvent("home triggered (long-press edge)")
        successTick()
    }

    /// Convenience for the UI test buttons.
    func testBack() { fireBack(duration: 0.2) }
    func testHome() { fireHome() }

    // MARK: - Injection

    /// Inject a synthetic system gesture: a left-edge swipe (iOS's native
    /// "back") or a bottom-edge swipe (iOS's native "home / app switcher"),
    /// paced to `duration` seconds.
    func injectSwipe(edge: Edge, duration: CFTimeInterval) {
        guard let digitizer = fnDigitizer, let dispatch = fnDispatchEvent, let client = client else {
            // Fallback path: the private API is gone, so only the in-app
            // gesture works; report it and stop here.
            logEvent("inject skipped (HID unavailable)")
            return
        }
        let w = Float(UIScreen.main.bounds.width)
        let h = Float(UIScreen.main.bounds.height)
        let begin = CACurrentMediaTime()
        var points: [(Float, Float)] = []
        if edge == .left {
            let midY = h / 2
            points = [(2, midY), (8, midY), (20, midY), (40, midY), (70, midY), (110, midY), (150, midY), (max(180, w * 0.35), midY)]
        } else {
            let midX = w / 2
            points = [(midX, h - 2), (midX, h - 8), (midX, h - 20), (midX, h - 40), (midX, h - 70), (midX, h - 110), (midX, h - 150), (midX, h - max(180, h * 0.35))]
        }
        let n = CFTimeInterval(points.count)
        for (i, p) in points.enumerated() {
            let sub: UInt32 = i == 0 ? kSubBegin : (i == points.count - 1 ? kSubEnd : kSubMove)
            // Ease-out timing: fast start, gentle finish (like a real finger).
            let f = CFTimeInterval(i) / n
            let eased = 1 - pow(1 - f, 2)
            let t = duration * eased
            let ev = digitizer(nil, UInt32((begin + t) * 1_000_000), kEventDigitizerType, sub, 0, 0, kDigitizerFingerType, p.0, p.1, 0, 1, 0)
            if let ev = ev { _ = dispatch(client, ev) }
        }
        print("EdgeReturn: injected \(edge == .left ? "back" : "home") swipe")
    }

    enum Edge { case left, bottom }

    // MARK: - HID event handling

    private func handleEvent(_ event: IOHIDEventRef?) {
        guard let event = event,
              let getEventType = fnGetEventType,
              let getFloat = fnGetFloat,
              let getInt = fnGetInt else { return }
        let type = getEventType(event)
        guard type == kEventDigitizerType else { return }
        let subType = getInt(event, 0x100009) // kIOHIDEventFieldDigitizerSubType
        let x = getFloat(event, 0x100000)     // kIOHIDEventFieldDigitizerX
        let y = getFloat(event, 0x100001)     // kIOHIDEventFieldDigitizerY
        let index = Int(getInt(event, 0x100004)) // kIOHIDEventFieldDigitizerIndex

        switch subType {
        case Int32(kSubBegin):
            beginTouch(index: index, x: x, y: y)
        case Int32(kSubMove):
            moveTouch(index: index, x: x, y: y)
        case Int32(kSubEnd):
            endTouch(index: index)
        default:
            break
        }
    }

    // MARK: - Fallback recognizer (in-app only)

    @objc private func handleFallbackPan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard !hidAvailable else { return }
        let location = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            beginTouch(index: 0, x: Float(location.x), y: Float(location.y))
        case .changed:
            moveTouch(index: 0, x: Float(location.x), y: Float(location.y))
        case .ended, .cancelled, .failed:
            endTouch(index: 0)
        default:
            break
        }
    }

    // MARK: - Long-press timer (fires even when the finger is perfectly still)

    private func startLongPressTimer() {
        longPressTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Snapshot first: checkLongPress mutates activeTouches.
            for track in self.activeTouches.values {
                self.checkLongPress(track)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        longPressTimer = t
    }

    // MARK: - Haptics (best effort, foreground only)

    private func engageTick() {
        guard hapticsEnabled else { return }
        playIntensity(0.35, sharpness: 0.8, duration: 0.04)
    }

    private func successTick() {
        guard hapticsEnabled else { return }
        playIntensity(0.6, sharpness: 0.9, duration: 0.08)
    }

    private func playIntensity(_ intensity: Float, sharpness: Float, duration: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            self?.playHaptic(intensity: intensity, sharpness: sharpness, duration: duration)
        }
    }

    private func playHaptic(intensity: Float, sharpness: Float, duration: TimeInterval) {
        if hapticEngine == nil {
            hapticEngine = try? CHHapticEngine()
        }
        guard let engine = hapticEngine else { return }
        try? engine.start()
        let event = CHHapticEvent(eventType: .hapticTypeSteadyState, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensityControl, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpnessControl, value: sharpness)
        ], duration: duration)
        guard let pattern = try? CHHapticPattern(events: [event], duration: duration + 0.02) else { return }
        try? engine.play(pattern)
    }

    // MARK: - Edge indicator + event log (UI, main thread)

    private func setEdgeIndicator(active: Bool, progress: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.edgeTouchActive = active
            self?.edgeTouchProgress = max(0, min(progress, 1))
        }
    }

    private func logEvent(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let line = "[\(stamp)] \(message)"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.eventLog.insert(line, at: 0)
            if self.eventLog.count > 8 {
                self.eventLog.removeLast(self.eventLog.count - 8)
            }
        }
    }
}
