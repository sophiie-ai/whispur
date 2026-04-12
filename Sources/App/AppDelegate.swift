import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AppDelegate")

/// Handles application lifecycle events.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Whispur launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Whispur terminating")
    }
}
