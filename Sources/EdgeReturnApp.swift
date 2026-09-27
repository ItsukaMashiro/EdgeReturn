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
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Start observing touches and the background keep-alive.
        TouchService.shared.startObserving()
        BackgroundKeeper.shared.start()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Re-assert the observer (in case the system tore it down) and the
        // keep-alive mechanisms.
        TouchService.shared.startObserving()
        BackgroundKeeper.shared.appDidBecomeActive()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        BackgroundKeeper.shared.reassert()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundKeeper.shared.appDidEnterBackground()
    }
}
