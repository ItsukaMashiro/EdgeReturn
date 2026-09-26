//
//  ContentView.swift
//  Main UI: enable the service, tune sensitivity, watch live touch events, and
//  test the back injection.
//

import SwiftUI

final class UIState: ObservableObject {
    @Published var backEnabled = false
    @Published var edgeThreshold: Double = 28
    @Published var minSwipeDistance: Double = 55
    @Published var observing = false
    @Published var locationActive = false
    @Published var audioActive = false
    @Published var lastTouch: CGPoint? = nil
    @Published var touchDown = false
    @Published var backFlash = false
    @Published var touchCount = 0

    private var flashReset: DispatchWorkItem?

    func start() {
        let svc = TouchService.shared
        svc.onTouchSample = { [weak self] location, down in
            DispatchQueue.main.async {
                self?.lastTouch = location
                self?.touchDown = down
                self?.touchCount += 1
            }
        }
        svc.onBackInjected = { [weak self] in
            DispatchQueue.main.async { self?.flashBack() }
        }
        refresh()
        // Poll status periodically.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.refresh()
        }
    }

    func refresh() {
        let svc = TouchService.shared
        observing = svc.observing
        svc.edgeThreshold = CGFloat(edgeThreshold)
        svc.minSwipeDistance = CGFloat(minSwipeDistance)
        svc.backEnabled = backEnabled
        locationActive = BackgroundKeeper.shared.locationActive
        audioActive = BackgroundKeeper.shared.audioActive
    }

    private func flashBack() {
        backFlash = true
        flashReset?.cancel()
        let item = DispatchWorkItem { self.backFlash = false }
        flashReset = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    func testBack() {
        TouchService.shared.testBack()
    }
}

struct ContentView: View {
    @StateObject private var state = UIState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                header
                statusRow
                toggleSection
                sensitivitySection
                Spacer(minLength: 8)
                debugView
                testButton
            }
            .padding(20)

            // Full-screen live touch overlay (behind the controls).
            TouchOverlay(lastTouch: state.lastTouch, touchDown: state.touchDown)
                .allowsHitTesting(false)

            // Back-injected flash.
            if state.backFlash {
                BackFlash()
                    .allowsHitTesting(false)
            }
        }
        .onAppear { state.start() }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("EdgeReturn")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Android-style right-edge swipe back")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.top, 6)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatusPill(label: "Observe", on: state.observing)
            StatusPill(label: "Location", on: state.locationActive)
            StatusPill(label: "Audio", on: state.audioActive)
            Spacer()
            Text("\(state.touchCount)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var toggleSection: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable back swipe")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Swipe from the right edge to go back")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Toggle("", isOn: $state.backEnabled)
                    .labelsHidden()
                    .onChange(of: state.backEnabled) { _ in state.refresh() }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        }
    }

    private var sensitivitySection: some View {
        VStack(spacing: 14) {
            slider(title: "Edge width", value: $state.edgeThreshold, range: 10...80, unit: "pt")
            slider(title: "Swipe distance", value: $state.minSwipeDistance, range: 30...150, unit: "pt")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private func slider(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).foregroundColor(.white)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.6))
            }
            Slider(value: value, in: range)
                .tint(.orange)
                .onChange(of: value.wrappedValue) { _ in state.refresh() }
        }
    }

    private var debugView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live touch events")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            Text(state.lastTouch.map { "x: \(Int($0.x))  y: \(Int($0.y))" } ?? "waiting…")
                .font(.caption.monospaced())
                .foregroundColor(state.lastTouch == nil ? .white.opacity(0.3) : .green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    private var testButton: some View {
        Button(action: { state.testBack() }) {
            Text("Test back (inject left-edge swipe)")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.orange))
        }
    }
}

// MARK: - Live touch overlay

struct TouchOverlay: View {
    let lastTouch: CGPoint?
    let touchDown: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Right-edge highlight band.
                Rectangle()
                    .fill(Color.orange.opacity(0.08))
                    .frame(width: 40)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if let p = lastTouch {
                    Circle()
                        .fill(touchDown ? Color.green : Color.green.opacity(0.35))
                        .frame(width: touchDown ? 26 : 16, height: touchDown ? 26 : 16)
                        .position(x: p.x, y: p.y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Back flash feedback

struct BackFlash: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
            HStack {
                Spacer()
                Image(systemName: "chevron.left")
                    .font(.system(size: 60, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.trailing, 24)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let label: String
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? Color.green : Color.white.opacity(0.25))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}
