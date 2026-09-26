//
//  TouchService.swift
//  Observes system-wide touch events via the private IOKit HID API and injects
//  synthetic touches (used to trigger the native left-edge back gesture).
//
//  The core idea:
//    1. We create an IOHIDEventSystemClient and register an event dispatch
//       callback. The system feeds us raw touch (digitizer) events from every
//       app on the device.
//    2. We watch for a touch that begins near the RIGHT edge and travels left
//       (Android-style back swipe).
//    3. When detected, we inject a synthetic LEFT-edge swipe, which is iOS's
//       native back gesture. Any app with back navigation then pops.
//

import Foundation
import CoreGraphics
import IOKit
import UIKit

final class TouchService: NSObject {
    static let shared = TouchService()

    // MARK: - Tunable configuration

    /// Distance (in points) from the right edge within which a touch is
    /// considered an "edge" touch.
    var edgeThreshold: CGFloat = 28

    /// Minimum leftward travel (in points) required to count as a back swipe.
    var minSwipeDistance: CGFloat = 55

    /// Master switch. When false, swipes are observed (for the debug view) but
    /// no back action is injected.
    var backEnabled: Bool = false

    // MARK: - Callbacks

    /// Fired when a qualifying right-edge swipe completes.
    var onRightEdgeSwipe: (() -> Void)?

    /// Fired for every observed touch sample (for the live debug view).
    /// (location in screen points, isProbablyDown)
    var onTouchSample: ((CGPoint, Bool) -> Void)?

    /// Fired when a back action is injected (for UI feedback).
    var onBackInjected: (() -> Void)?

    // MARK: - State

    private var client: IOHIDEventSystemClientRef?
    private var isObserving = false
    private let workQueue = DispatchQueue(label: "touch.service.work", qos: .userInteractive)

    struct TouchTrack {
        var startX: CGFloat
        var startY: CGFloat
        var startTime: CFTimeInterval
        var lastX: CGFloat
        var lastY: CGFloat
        var lastTime: CFTimeInterval
        var isRightEdge: Bool
        var consumed: Bool
    }
    private var activeTouches: [Int: TouchTrack] = [:]
    private var nextTouchID = 0

    // IOKit HID field / type constants (private values).
    private let kDigitizerType: UInt32 = 13            // kIOHIDEventTypeDigitizer
    private let kFieldX: Int = 0x100000               // kIOHIDEventFieldDigitizerX
    private let kFieldY: Int = 0x100001               // kIOHIDEventFieldDigitizerY
    private let kSubBegin: UInt32 = 1                 // touch down
    private let kSubMove: UInt32 = 3                 // move
    private let kSubEnd: UInt32 = 2                 // touch up
    private let kDigitizerTouch: UInt32 = 1          // kIOHIDEventDigitizerTypeTouch

    override init() {
        super.init()
    }

    deinit {
        stopObserving()
    }

    // MARK: - Observation

    /// Begin observing system-wide touch events. Safe to call repeatedly.
    @discardableResult
    func startObserving() -> Bool {
        guard !isObserving else { return true }
        var clientRef: IOHIDEventSystemClientRef?
        let result = IOHIDEventSystemClientCreate(kCFAllocatorDefault, &clientRef)
        guard result == KERN_SUCCESS, let clientRef = clientRef else {
            print("[TouchService] IOHIDEventSystemClientCreate failed: \(result)")
            return false
        }
        self.client = clientRef

        let context = Unmanaged.passUnretained(self).toOpaque()
        let setResult = IOHIDEventSystemClientSetEventDispatchFunction(
            clientRef,
            { ctx, event in
                guard let ctx = ctx else { return }
                let service = Unmanaged<TouchService>.fromOpaque(ctx).takeUnretainedValue()
                service.handleEvent(event)
            },
            context
        )
        if setResult != KERN_SUCCESS {
            print("[TouchService] SetEventDispatchFunction failed: \(setResult)")
            return false
        }
        isObserving = true
        print("[TouchService] Observing touch events")
        return true
    }

    func stopObserving() {
        guard isObserving else { return }
        if let client = client {
            IOHIDEventSystemClientSetEventDispatchFunction(client, nil, nil)
            IOHIDEventSystemClientDestroy(client)
        }
        client = nil
        isObserving = false
        activeTouches.removeAll()
        print("[TouchService] Stopped observing")
    }

    // MARK: - Event handling

    private func handleEvent(_ event: IOHIDEventRef) {
        let type = IOHIDEventGetEventType(event)
        guard type.rawValue == kDigitizerType else { return }

        let x = CGFloat(IOHIDEventGetFloatValue(event, kFieldX))
        let y = CGFloat(IOHIDEventGetFloatValue(event, kFieldY))
        guard x >= 0, y >= 0 else { return }

        workQueue.async { [weak self] in
            self?.processTouch(x: x, y: y)
        }
    }

    private func processTouch(x: CGFloat, y: CGFloat) {
        let now = CACurrentMediaTime()
        let screen = UIScreen.main.bounds
        let location = CGPoint(x: x, y: y)

        // Report the sample for the debug view.
        let isDown = activeTouches.isEmpty || nearestTouch(to: location) == nil
        DispatchQueue.main.async { [weak self] in
            self?.onTouchSample?(location, isDown)
        }

        // Find the nearest tracked touch.
        var nearestKey: Int? = nil
        var nearestDist: CGFloat = .infinity
        for (key, track) in activeTouches {
            let d = hypot(track.lastX - x, track.lastY - y)
            if d < nearestDist {
                nearestDist = d
                nearestKey = key
            }
        }

        if let key = nearestKey, nearestDist < 40 {
            // Move: update the existing track.
            if var track = activeTouches[key] {
                track.lastX = x
                track.lastY = y
                track.lastTime = now
                activeTouches[key] = track
                checkSwipe(track)
            }
        } else {
            // New touch (begin).
            nextTouchID += 1
            let key = nextTouchID
            let isRightEdge = x > (screen.width - edgeThreshold)
            activeTouches[key] = TouchTrack(
                startX: x, startY: y, startTime: now,
                lastX: x, lastY: y, lastTime: now,
                isRightEdge: isRightEdge, consumed: false
            )
        }

        // Drop stale touches.
        activeTouches = activeTouches.filter { now - $0.value.lastTime < 0.6 }
    }

    private func nearestTouch(to p: CGPoint) -> TouchTrack? {
        var best: TouchTrack? = nil
        var bestD: CGFloat = .infinity
        for track in activeTouches.values {
            let d = hypot(track.lastX - p.x, track.lastY - p.y)
            if d < bestD {
                bestD = d
                best = track
            }
        }
        return best
    }

    private func checkSwipe(_ track: TouchTrack) {
        guard track.isRightEdge, !track.consumed else { return }
        let dx = track.startX - track.lastX   // positive when moved left
        if dx > minSwipeDistance {
            // Qualifying right-edge swipe.
            if backEnabled {
                injectLeftEdgeSwipe()
            }
            // Mark consumed so a single swipe only triggers once.
            if var t = activeTouches.first(where: { $0.value.startX == track.startX && $0.value.startY == track.startY }) {
                t.value.consumed = true
                activeTouches[t.key] = t.value
            }
        }
    }

    // MARK: - Injection

    /// Inject a synthetic left-edge swipe to trigger the native back gesture.
    func injectLeftEdgeSwipe() {
        guard let client = client else {
            print("[TouchService] No client for injection")
            return
        }
        let screen = UIScreen.main.bounds
        let startY = screen.height * 0.5

        // HID timestamps are 32-bit microseconds.
        let base = UInt32((CACurrentMediaTime() * 1_000_000)
            .truncatingRemainder(dividingBy: 4_294_967_296))
        let step: UInt32 = 8_000   // 8 ms between events

        // 1. Touch down at the left edge.
        dispatchDigitizer(client, timestamp: base, subType: kSubBegin,
                         x: 0, y: startY, inRange: true)
        // 2. Move right (the native back gesture direction).
        for i in 1...12 {
            let x = CGFloat(i) * 18
            dispatchDigitizer(client,
                             timestamp: base + UInt32(i) * step,
                             subType: kSubMove, x: x, y: startY, inRange: true)
        }
        // 3. Touch up.
        dispatchDigitizer(client,
                         timestamp: base + 13 * step,
                         subType: kSubEnd, x: 220, y: startY, inRange: false)

        DispatchQueue.main.async { [weak self] in
            self?.onBackInjected?()
        }
        print("[TouchService] Injected left-edge swipe (back)")
    }

    private func dispatchDigitizer(_ client: IOHIDEventSystemClientRef,
                                  timestamp: UInt32, subType: UInt32,
                                  x: CGFloat, y: CGFloat, inRange: Bool) {
        guard let event = IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault,
            timestamp,
            kDigitizerType,
            subType,
            0,            // index
            inRange ? 1 : 0,   // range
            kDigitizerTouch,
            Float32(x),
            Float32(y),
            0,            // z
            inRange ? 1.0 : 0.0,  // v (pressure)
            0             // options
        ) else { return }
        IOHIDEventSystemClientDispatchEvent(client, event)
        CFRelease(event)
    }

    // MARK: - Diagnostics

    /// Force a single back injection (for the "Test back" button).
    func testBack() {
        _ = startObserving()
        injectLeftEdgeSwipe()
    }

    var observing: Bool { isObserving }
}
