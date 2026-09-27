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
//    PACED TO THE USER'S ACTUAL SWIPE TIME (clamped 0.12s...0.4s), so
//    the native back animation follows the pace of your finger — the
//    core of the Android feel;
//  - a long-press in the edge zone (optional, `longPressEnabled`) injects
//    a bottom-edge swipe (home / app switcher), like Android's
//    long-press-edge;
//  - releasing short of the thresholds cancels (indicator fades out),
//    exactly like Android's cancelable drag.
//
//  CALIBRATION (v2):
//  - The first ~40 raw events are logged verbatim (type/sub/x/y/index) so
//    the real on-device encoding of the private API is visible in the UI.
//  - Touches are tracked BEHAVIORALLY (index appears / moves / goes
//    silent), so observation works regardless of the subType encoding.
//  - Injection uses one of two constant sets (A = modern values, B =
//    2010-header values); the UI lets you pick which one the gesture
//    engine uses, and dedicated test buttons fire each set so the one
//    that actually makes the system go back can be identified.
//

import Foundation
import CoreGraphics
import UIKit
import QuartzCore

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
    /// Which constant set the gesture engine injects with ("A" or "B").
    @Published var injectionSet: String = "A"

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
    private var touchTimer: Timer?

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
    private var impactLight: UIImpactFeedbackGenerator?
    private var impactMedium: UIImpactFeedbackGenerator?

    /// One in-flight touch, keyed by the event's digitizer index (stable per
    /// finger, unlike a synthetic id we would have to invent ourselves).
    private struct TouchTrack {
        var index: Int
        var startX: Float
        var startY: Float
        var lastX: Float
        var lastY: Float
        var startTime: TimeInterval
        var lastSeen: TimeInterval
        var engaged: Bool
        var triggered: Bool
        var longPressFired: Bool
    }
    private var activeTouches: [Int: TouchTrack] = [:]

    // MARK: - Private API constant sets (calibration)

    struct HIDConstants {
        let name: String
        let eventType: UInt32
        let subBegin: UInt32
        let subMove: UInt32
        let subEnd: UInt32
        let fingerType: UInt32
    }

    /// Set A: the values this app shipped with (modern private-header
    /// values as understood by the original author).
    static let constantsA = HIDConstants(
        name: "A", eventType: 30, subBegin: 1, subMove: 3, subEnd: 2, fingerType: 13
    )
    /// Set B: the 2010 public-ish header values (Digitizer type 11,
    /// field base 0xB00000, Finger transducer 34, subtypes 0/1/2).
    static let constantsB = HIDConstants(
        name: "B", eventType: 11, subBegin: 0, subMove: 2, subEnd: 1, fingerType: 34
    )

    /// Field ids for the two sets.
    static let fieldsA: (x: Int32, y: Int32, index: Int32, sub: Int32) = (0x100000, 0x100001, 0x100004, 0x100009)
    static let fieldsB: (x: Int32, y: Int32, index: Int32, sub: Int32) = (0x000B0000, 0x000B0001, 0x000B0005, 0x000B0009)

    /// The digitizer event type as learned from live events (nil until seen).
    private var learnedDigitizerType: UInt32?
    private var rawEventCount = 0

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
                    startTouchTimer()
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
        activeTouches[index] = TouchTrack(
            index: index, startX: x, startY: y, lastX: x, lastY: y,
            startTime: now, lastSeen: now, engaged: false, triggered: false, longPressFired: false
        )
        let inEdge = x >= Float(UIScreen.main.bounds.width) - edgeThreshold
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
        track.lastSeen = CACurrentMediaTime()
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

    private func currentConstants() -> HIDConstants {
        injectionSet == "B" ? TouchService.constantsB : TouchService.constantsA
    }

    private func fireBack(duration: CFTimeInterval) {
        injectSwipe(edge: .left, duration: duration, constants: currentConstants())
        lastBackAt = Date()
        logEvent("back triggered (set \(currentConstants().name), paced \(Int(duration * 1000))ms)")
        successTick()
    }

    private func fireHome() {
        injectSwipe(edge: .bottom, duration: 0.25, constants: currentConstants())
        lastHomeAt = Date()
        logEvent("home triggered (set \(currentConstants().name), long-press edge)")
        successTick()
    }

    /// Convenience for the UI test buttons: fire a given constant set.
    func testBack(set: String) {
        let c = set == "B" ? TouchService.constantsB : TouchService.constantsA
        injectSwipe(edge: .left, duration: 0.2, constants: c)
        lastBackAt = Date()
        logEvent("TEST back (set \(c.name))")
    }

    func testHome(set: String) {
        let c = set == "B" ? TouchService.constantsB : TouchService.constantsA
        injectSwipe(edge: .bottom, duration: 0.25, constants: c)
        lastHomeAt = Date()
        logEvent("TEST home (set \(c.name))")
    }

    // MARK: - Injection

    /// Inject a synthetic system gesture: a left-edge swipe (iOS's native
    /// "back") or a bottom-edge swipe (iOS's native "home / app switcher"),
    /// paced to `duration` seconds, using the given constant set.
    @discardableResult
    func injectSwipe(edge: Edge, duration: CFTimeInterval, constants: HIDConstants) -> Int32 {
        guard let digitizer = fnDigitizer, let dispatch = fnDispatchEvent, let client = client else {
            logEvent("inject skipped (HID unavailable)")
            return -1
        }
        let w = Float(UIScreen.main.bounds.width)
        let h = Float(UIScreen.main.bounds.height)
        let begin = mach_absolute_time()
        var points: [(Float, Float)] = []
        if edge == .left {
            let midY = h / 2
            points = [(2, midY), (8, midY), (20, midY), (40, midY), (70, midY), (110, midY), (150, midY), (max(180, w * 0.35), midY)]
        } else {
            let midX = w / 2
            points = [(midX, h - 2), (midX, h - 8), (midX, h - 20), (midX, h - 40), (midX, h - 70), (midX, h - 110), (midX, h - 150), (midX, h - max(180, h * 0.35))]
        }
        let n = CFTimeInterval(points.count)
        var lastKR: Int32 = -1
        for (i, p) in points.enumerated() {
            let sub: UInt32
            if i == 0 {
                sub = constants.subBegin
            } else if i == points.count - 1 {
                sub = constants.subEnd
            } else {
                sub = constants.subMove
            }
            // Ease-out timing: fast start, gentle finish (like a real finger).
            let f = CFTimeInterval(i) / n
            let eased = 1 - pow(1 - f, 2)
            // mach_absolute_time() ticks: spread the gesture over `duration`.
            let totalTicks = UInt64(duration * 24_000_000.0) // Apple silicon mach tick ≈ 24 MHz
            let t = UInt32(truncatingIfNeeded: begin + UInt64(Double(totalTicks) * eased))
            let ev = digitizer(nil, t, constants.eventType, sub, 0, 0, constants.fingerType, p.0, p.1, 0, 1, 0)
            if let ev = ev { lastKR = dispatch(client, ev) }
        }
        logEvent("injected \(edge == .left ? "back" : "home") (set \(constants.name)) kr=\(lastKR)")
        return lastKR
    }

    enum Edge { case left, bottom }

    // MARK: - HID event handling

    private func handleEvent(_ event: IOHIDEventRef?) {
        guard let event = event,
              let getEventType = fnGetEventType,
              let getFloat = fnGetFloat,
              let getInt = fnGetInt else { return }
        let type = getEventType(event)
        // Read with BOTH field sets so the raw log shows which one is sane.
        let subA = getInt(event, Self.fieldsA.sub)
        let subB = getInt(event, Self.fieldsB.sub)
        let xA = getFloat(event, Self.fieldsA.x)
        let yA = getFloat(event, Self.fieldsA.y)
        let xB = getFloat(event, Self.fieldsB.x)
        let yB = getFloat(event, Self.fieldsB.y)
        let idxA = Int(getInt(event, Self.fieldsA.index))
        let idxB = Int(getInt(event, Self.fieldsB.index))

        // Raw diagnostics: the first ~40 events, verbatim, both encodings.
        if rawEventCount < 40 {
            rawEventCount += 1
            logEvent("raw#\(rawEventCount) t=\(type) sA=\(subA) sB=\(subB) xA=\(Int(xA)) yA=\(Int(yA)) xB=\(Int(xB)) yB=\(Int(yB)) iA=\(idxA) iB=\(idxB)")
        }

        // Auto-learn the digitizer event type from the first event whose
        // coordinates land in a plausible screen range.
        if learnedDigitizerType == nil {
            let w = Float(UIScreen.main.bounds.width)
            let h = Float(UIScreen.main.bounds.height)
            let saneA = xA >= 0 && xA <= w && yA >= 0 && yA <= h
            let saneB = xB >= 0 && xB <= w && yB >= 0 && yB <= h
            if saneA {
                learnedDigitizerType = type
                logEvent("learned digitizer type=\(type) (fields A)")
            } else if saneB {
                learnedDigitizerType = type
                logEvent("learned digitizer type=\(type) (fields B)")
            }
        }
        guard let learned = learnedDigitizerType, type == learned else { return }

        // Pick the sane field set for this event.
        let w = Float(UIScreen.main.bounds.width)
        let h = Float(UIScreen.main.bounds.height)
        let useA = (xA >= 0 && xA <= w && yA >= 0 && yA <= h)
        let x = useA ? xA : xB
        let y = useA ? yA : yB
        let index = useA ? idxA : idxB
        let sub = useA ? subA : subB

        let now = CACurrentMediaTime()
        if var track = activeTouches[index] {
            // Explicit end subtypes (either encoding) close the touch.
            let isEnd = (sub == Int32(TouchService.constantsA.subEnd) || sub == Int32(TouchService.constantsB.subEnd))
            if isEnd {
                endTouch(index: index)
                return
            }
            track.lastX = x
            track.lastY = y
            track.lastSeen = now
            activeTouches[index] = track
            checkEngage(track)
            checkLongPress(track)
            let dx = x - track.startX
            let progress = Double(min(max(-dx / completeDistance, 0), 1))
            setEdgeIndicator(active: true, progress: progress)
        } else {
            // First sight of this index: a begin.
            beginTouch(index: index, x: x, y: y)
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

    // MARK: - Touch timer (long-press + silent-end detection)

    private func startTouchTimer() {
        touchTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            // Long-press check (fires even when the finger is perfectly still).
            // Snapshot first: checkLongPress mutates activeTouches.
            for track in Array(self.activeTouches.values) {
                self.checkLongPress(track)
            }
            // Silent end: a touch index that has not sent an event for 250ms
            // is considered lifted (covers subType encodings we don't know).
            for (index, track) in Array(self.activeTouches) where !track.triggered {
                if now - track.lastSeen > 0.25 {
                    self.endTouch(index: index)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        touchTimer = t
    }

    // MARK: - Haptics (best effort, foreground only)

    private func engageTick() {
        guard hapticsEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.impactLight == nil {
                self.impactLight = UIImpactFeedbackGenerator(style: .light)
            }
            self.impactLight?.impactOccurred()
        }
    }

    private func successTick() {
        guard hapticsEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.impactMedium == nil {
                self.impactMedium = UIImpactFeedbackGenerator(style: .medium)
            }
            self.impactMedium?.impactOccurred()
        }
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
            if self.eventLog.count > 14 {
                self.eventLog.removeLast(self.eventLog.count - 14)
            }
        }
    }
}
