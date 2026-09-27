//
//  ContentView.swift
//  Main UI: enable the service, tune sensitivity, watch service status,
//  preview the live edge indicator, and test the gesture injection.
//  All settings persist across launches (UserDefaults via @AppStorage).
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var svc = TouchService.shared
    @ObservedObject private var keeper = BackgroundKeeper.shared

    // Persisted tuning.
    @AppStorage("edgeThreshold") private var edgeThreshold: Double = 28
    @AppStorage("engageDistance") private var engageDistance: Double = 35
    @AppStorage("completeDistance") private var completeDistance: Double = 55
    @AppStorage("backEnabled") private var backEnabled = true
    @AppStorage("longPressEnabled") private var longPressEnabled = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("preventSleep") private var preventSleep = false
    @AppStorage("injectionSet") private var injectionSet: String = "A"

    @State private var backFlash = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusRow
                    gestureSection
                    sensitivitySection
                    serviceSection
                    testSection
                    eventLogSection
                }
                .padding(20)
            }

            // Live edge indicator: a thin bar on the RIGHT edge (Android's
            // drag indicator) that lights up and grows while a touch is in
            // the edge zone.
            edgeIndicator

            if backFlash {
                BackFlash().allowsHitTesting(false)
            }
        }
        .onAppear {
            syncTuning()
            TouchService.shared.startObserving()
            BackgroundKeeper.shared.start()
        }
        .onChange(of: svc.lastBackAt) { _ in flashBack() }
        .onChange(of: injectionSet) { _ in svc.injectionSet = injectionSet }
        .onChange(of: edgeThreshold) { _ in svc.edgeThreshold = Float(edgeThreshold) }
        .onChange(of: engageDistance) { _ in svc.engageDistance = Float(engageDistance) }
        .onChange(of: completeDistance) { _ in svc.completeDistance = Float(completeDistance) }
        .onChange(of: backEnabled) { _ in svc.backEnabled = backEnabled }
        .onChange(of: longPressEnabled) { _ in svc.longPressEnabled = longPressEnabled }
        .onChange(of: hapticsEnabled) { _ in svc.hapticsEnabled = hapticsEnabled }
        .onChange(of: preventSleep) { _ in keeper.preventSleep = preventSleep }
        .preferredColorScheme(.dark)
    }

    private func syncTuning() {
        svc.edgeThreshold = Float(edgeThreshold)
        svc.engageDistance = Float(engageDistance)
        svc.completeDistance = Float(completeDistance)
        svc.backEnabled = backEnabled
        svc.longPressEnabled = longPressEnabled
        svc.hapticsEnabled = hapticsEnabled
        svc.injectionSet = injectionSet
        keeper.preventSleep = preventSleep
    }

    // MARK: - Sections

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
        HStack(spacing: 8) {
            StatusPill(label: "HID", on: svc.isObserving)
            StatusPill(label: "Location", on: keeper.locationActive)
            StatusPill(label: "Audio", on: keeper.audioActive)
            StatusPill(label: "Watchdog", on: keeper.watchdogBeats > 0)
            Spacer()
        }
    }

    private var gestureSection: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $backEnabled) {
                Text("Right-edge swipe → back")
                    .font(.body).foregroundColor(.white)
            }
            .tint(.green)

            Toggle(isOn: $longPressEnabled) {
                Text("Long-press edge → home / apps")
                    .font(.body).foregroundColor(.white)
            }
            .tint(.green)

            Toggle(isOn: $hapticsEnabled) {
                Text("Haptic ticks (Android feel)")
                    .font(.body).foregroundColor(.white)
            }
            .tint(.green)

            Toggle(isOn: $preventSleep) {
                Text("Keep screen awake")
                    .font(.body).foregroundColor(.white)
            }
            .tint(.green)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private var sensitivitySection: some View {
        VStack(spacing: 14) {
            Text("Sensitivity")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            sliderRow(title: "Edge width", value: $edgeThreshold, range: 12...60, unit: "pt")
            sliderRow(title: "Engage distance", value: $engageDistance, range: 20...80, unit: "pt")
            sliderRow(title: "Complete distance", value: $completeDistance, range: 30...120, unit: "pt")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.white.opacity(0.6))
            }
            Slider(value: value, in: range)
                .tint(.green)
        }
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gesture engine", systemImage: "cpu")
                    .font(.caption)
                    .foregroundColor(svc.hidAvailable ? .green : .orange)
                Spacer()
                Text(svc.hidDetail)
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.6))
            }
            HStack {
                Label("App state", systemImage: keeper.inBackground ? "moon.fill" : "sun.max.fill")
                    .font(.caption)
                    .foregroundColor(keeper.inBackground ? .orange : .green)
                Spacer()
                Text(keeper.inBackground ? "background (keep-alive active)" : "foreground")
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.6))
            }
            HStack {
                Label("Location auth", systemImage: "location")
                    .font(.caption)
                    .foregroundColor(keeper.locationDenied ? .red : .green)
                Spacer()
                if keeper.locationDenied {
                    Button("Open Settings") { keeper.openAppSettings() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.orange)
                } else {
                    Text(keeper.locationActive ? "granted" : "pending")
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            if let last = svc.lastBackAt {
                HStack {
                    Label("Last back", systemImage: "chevron.left")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Text(last, style: .time)
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            if let last = svc.lastHomeAt {
                HStack {
                    Label("Last home", systemImage: "house")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Text(last, style: .time)
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Text("Keep-alive: location + silent audio + watchdog. Grant \"Always\" for location when asked. iOS may still kill the app under extreme memory pressure — relaunch to resume.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private var testSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { svc.testBack(set: injectionSet) } label: {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Test back")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange))
                }
                .disabled(!svc.isObserving)
                .opacity(svc.isObserving ? 1 : 0.5)

                Button { svc.testHome(set: injectionSet) } label: {
                    HStack {
                        Image(systemName: "house")
                        Text("Test home")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.green))
                }
                .disabled(!svc.isObserving)
                .opacity(svc.isObserving ? 1 : 0.5)
            }
            // Calibration: which private-API constant set to inject with.
            HStack(spacing: 8) {
                Text("Injection set")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                Picker("", selection: $injectionSet) {
                    Text("A (modern)").tag("A")
                    Text("B (2010 hdr)").tag("B")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                Spacer()
            }
            Text("Calibration: the event log shows raw events (both field encodings). Pick the set whose test button actually makes the system go back / home.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var eventLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Event log")
                .font(.headline)
                .foregroundColor(.white)
            if svc.eventLog.isEmpty {
                Text("No events yet — swipe in from the right edge.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(svc.eventLog, id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    // MARK: - Live edge indicator (right edge, Android drag indicator)

    private var edgeIndicator: some View {
        GeometryReader { geo in
            Capsule()
                .fill(svc.edgeTouchActive ? Color.orange : Color.white.opacity(0.15))
                .frame(width: 4, height: max(44, 44 + CGFloat(svc.edgeTouchProgress) * geo.size.height * 0.35))
                .shadow(color: svc.edgeTouchActive ? Color.orange.opacity(0.8) : .clear, radius: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 3)
                .animation(.easeOut(duration: 0.12), value: svc.edgeTouchActive)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func flashBack() {
        backFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            backFlash = false
        }
    }
}

// MARK: - Back flash

struct BackFlash: View {
    var body: some View {
        HStack {
            Spacer()
            Image(systemName: "chevron.left")
                .font(.system(size: 60, weight: .bold))
                .foregroundColor(.orange)
                .padding(.trailing, 24)
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
