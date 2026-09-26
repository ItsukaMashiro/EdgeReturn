//
//  EdgeReturnApp.swift
//  App entry point. Wires the touch service, background keeper, and UI together.
//

import SwiftUI
import UIKit

@main
struct EdgeReturnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    AppDelegate.bootstrap()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var booted = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Start observing touches and the background keep-alive.
        TouchService.shared.startObserving()
        BackgroundKeeper.shared.start()

        // React to a qualifying right-edge swipe by injecting the back gesture.
        TouchService.shared.onRightEdgeSwipe = {
            // onRightEdgeSwipe is informational; the actual injection happens in
            // TouchService.checkSwipe when backEnabled is true.
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        TouchService.shared.startObserving()
        BackgroundKeeper.shared.start()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Keep observing in the background.
    }

    static func bootstrap() {
        guard !booted else { return }
        booted = true
        TouchService.shared.startObserving()
        BackgroundKeeper.shared.start()
    }
}
