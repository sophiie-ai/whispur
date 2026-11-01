import AppKit
import SwiftUI
import XCTest
@testable import Whispur

/// Renders the real recording overlay panel and checks that its shadow
/// fades out inside the panel instead of being cut off at the panel edge,
/// which shows as a faint box around the pill.
///
/// Set `WHISPUR_RENDER_OVERLAY` (pass `TEST_RUNNER_WHISPUR_RENDER_OVERLAY=1`
/// to xcodebuild) to also write PNGs over a light and a dark desktop to
/// `WHISPUR_RENDER_DIR`, default /tmp/whispur-overlay-fix.
@MainActor
final class OverlayRenderTests: XCTestCase {
    private static let scale = 4

    private static let waveform: [Float] = (0..<DictationPipeline.waveformSampleCount).map { index in
        Float(0.35 + 0.3 * sin(Double(index) * 0.9))
    }

    func testCompactPillShadowFadesOutInsideThePanel() throws {
        try checkPanel(style: .compact, phase: .recording, name: "compact-recording")
        try checkPanel(style: .compact, phase: .transcribing, name: "compact-processing")
    }

    func testStandardOverlayShadowFadesOutInsideThePanel() throws {
        try checkPanel(style: .standard, phase: .recording, name: "standard-recording")
    }

    /// Streaming on: live words under the standard overlay and beside the
    /// compact waveform, short and long enough to be cut.
    func testLiveWordsWhileStreaming() throws {
        let short = "Can we push the design review"
        let long = "Can we push the design review to Thursday afternoon so everyone gets a chance to see the new onboarding flow before we decide on the empty states"
        try checkPanel(style: .standard, phase: .recording, name: "standard-live-empty", live: "")
        try checkPanel(style: .standard, phase: .recording, name: "standard-live-short", live: short)
        try checkPanel(style: .standard, phase: .recording, name: "standard-live-long", live: long)
        try checkPanel(style: .standard, phase: .transcribing, name: "standard-live-transcribing", live: long)
        try checkPanel(style: .compact, phase: .recording, name: "compact-live-short", live: "Can we push")
        try checkPanel(style: .compact, phase: .recording, name: "compact-live-long", live: long)
    }

    func testLiveTranscriptTailKeepsTheNewestWholeWords() {
        XCTAssertEqual(LiveTranscriptTail.tail("  ship   it\nnow ", budget: 30).text, "ship it now")
        XCTAssertEqual(LiveTranscriptTail.tail("ship it now", budget: 30).truncated, false)
        let cut = LiveTranscriptTail.tail("one two three four five", budget: 12)
        XCTAssertEqual(cut.text, "four five")
        XCTAssertTrue(cut.truncated)
        XCTAssertEqual(LiveTranscriptTail.tail("supercalifragilistic", budget: 5).text, "istic")
    }

    func testUseRawToastShadowFadesOutInsideThePanel() throws {
        let controller = UseRawController()
        let toast = UseRawToastPanelManager()
        toast.bind(to: controller, styleProvider: { .standard })
        controller.setOfferForRendering(UseRawOffer.Offer(
            dictationID: UUID(), rawTranscript: "um ship it", pastedText: "Ship it.",
            processID: 1, bundleID: nil, expiresAt: .distantFuture
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let panel = try XCTUnwrap(toast.panelForTesting)
        try checkRendered(panel: panel, name: "use-raw-toast")
        panel.orderOut(nil)
    }

    private func checkPanel(style: OverlayStyle, phase: PipelinePhase, name: String, live: String? = nil) throws {
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: ProviderHTTPClient(requestLog: ProviderRequestLog(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("overlay-requests-\(UUID().uuidString).json")
            ))),
            historyStore: PipelineHistoryStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("overlay-history-\(UUID().uuidString).json")
            )
        )
        if live != nil {
            pipeline.streamingEnabled = true
            pipeline.selectedSTT = .elevenlabs
        }
        let overlay = OverlayPanelManager()
        overlay.bind(to: pipeline, styleProvider: { style }, onStop: {}, onCancel: {})
        pipeline.setPhaseForRendering(phase, samples: Self.waveform, liveTranscript: live)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let panel = try XCTUnwrap(overlay.panelForTesting)
        try checkRendered(panel: panel, name: name)
    }

    private func checkRendered(panel: NSPanel, name: String) throws {
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let size = panel.frame.size
        let rep = try snapshot(content, size: size)

        // The outermost ring of the panel must be fully transparent: any
        // shadow left there is cut off by the window edge.
        let edgeAlpha = Self.maxAlpha(in: rep) { x, y, width, height in
            x == 0 || y == 0 || x == width - 1 || y == height - 1
        }
        XCTAssertLessThanOrEqual(edgeAlpha, 2, "\(name): the shadow is clipped by the panel edge (edge alpha \(edgeAlpha))")

        // Known-positive control: the shadow does draw somewhere outside
        // the pill, so a clean edge means it faded out, not that nothing
        // was rendered.
        let shadowAlpha = Self.maxAlpha(in: rep) { x, y, width, height in
            let inset = 3 * Self.scale
            return x == inset || y == inset || x == width - 1 - inset || y == height - 1 - inset
        }
        XCTAssertGreaterThan(shadowAlpha, 0, "\(name): nothing rendered near the panel edge, so the check proves nothing")

        if let dir = Self.renderDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.png(rep).write(to: dir.appendingPathComponent("\(name)-transparent.png"))
            for (backgroundName, color) in [("light", NSColor(white: 0.93, alpha: 1)), ("dark", NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))] {
                try Self.png(Self.composite(rep, size: size, over: color)).write(
                    to: dir.appendingPathComponent("\(name)-\(backgroundName).png")
                )
            }
        }
    }

    // MARK: - Helpers

    private static var renderDirectory: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["WHISPUR_RENDER_OVERLAY"] != nil else { return nil }
        return URL(fileURLWithPath: env["WHISPUR_RENDER_DIR"] ?? "/tmp/whispur-overlay-fix")
    }

    private func snapshot(_ view: NSView, size: CGSize) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * Self.scale,
            pixelsHigh: Int(size.height) * Self.scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        view.cacheDisplay(in: CGRect(origin: .zero, size: size), to: rep)
        return rep
    }

    private static func maxAlpha(
        in rep: NSBitmapImageRep,
        where include: (_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Bool
    ) -> Int {
        var maximum = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where include(x, y, rep.pixelsWide, rep.pixelsHigh) {
                var pixel = [Int](repeating: 0, count: 4)
                rep.getPixel(&pixel, atX: x, y: y)
                maximum = max(maximum, pixel[3])
            }
        }
        return maximum
    }

    private static func composite(_ rep: NSBitmapImageRep, size: CGSize, over color: NSColor) -> NSBitmapImageRep {
        let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        color.setFill()
        CGRect(origin: .zero, size: size).fill()
        rep.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    private static func png(_ rep: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
