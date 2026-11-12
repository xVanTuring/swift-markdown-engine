//
//  WideTableScrollGestureTests.swift
//  MarkdownEngineTests
//
//  A trackpad gesture over a wide table goes to ONE scroll view, start to end.
//
//  The overlay used to route each event by its own axis. A gesture's touch
//  down, lift and momentum end carry no delta, so they went to the document
//  while the movement went to the table: the table never saw its gesture end,
//  dropped the momentum, and a flicked table stopped dead when the fingers
//  lifted.
//
//  The momentum itself is not measured here: AppKit does not apply synthesized
//  momentum events in a test (the document's scroll view, whose momentum works
//  in the app, moves by 0 too). What is measured is where every event goes and
//  that the table sees its gesture end.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wide table — a trackpad gesture goes to one scroll view", .serialized)
struct WideTableScrollGestureTests {

    /// Synthesized scroll event. `phase` / `momentum` are the raw CGEvent values
    /// (began 1, changed 2, ended 4, cancelled 8, mayBegin 128; momentum begin 1,
    /// continue 2, end 3). `continuous: false` is a mouse wheel notch.
    private static func event(dx: Int32 = 0, dy: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0,
                              continuous: Bool = true) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line,
                            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        if continuous {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(dy) * 65536)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(dx) * 65536)
        }
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum)
        return NSEvent(cgEvent: event)!
    }

    /// A flick along one axis: touch down, a held drag, lift, momentum.
    private static func flick(dx: Int32 = 0, dy: Int32 = 0) -> [() -> NSEvent] {
        var events: [() -> NSEvent] = [{ event(phase: 128) }, { event(dx: dx, dy: dy, phase: 1) }]
        for _ in 0..<10 { events.append { event(dx: dx, dy: dy, phase: 2) } }
        events.append { event(phase: 4) }
        events.append { event(dx: dx * 3, dy: dy * 3, momentum: 1) }
        for _ in 0..<6 { events.append { event(dx: dx * 2, dy: dy * 2, momentum: 2) } }
        events.append { event(momentum: 3) }
        return events
    }

    /// The document's scroll view, recording what reaches it.
    private final class DocumentScrollView: NSScrollView {
        private(set) var received: [NSEvent] = []
        override func scrollWheel(with event: NSEvent) {
            received.append(event)
            super.scrollWheel(with: event)
        }
    }

    private final class LiveScrollCounter: NSObject {
        private(set) var started = 0
        private(set) var ended = 0
        init(_ scrollView: NSScrollView) {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(start),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(end),
                                                   name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }
        @objc private func start() { started += 1 }
        @objc private func end() { ended += 1 }
    }

    private struct Fixture {
        let window: NSWindow
        let document: DocumentScrollView
        let table: WideTableOverlay
    }

    /// A 400pt-wide table showing 2000pt of table, scrolled to 600pt, inside a document.
    private func makeFixture() -> Fixture {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let document = DocumentScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        document.documentView = textView
        window.contentView = document
        window.orderFrontRegardless()

        let table = WideTableOverlay(sourceID: 1, image: NSImage(size: NSSize(width: 2000, height: 100)),
                                     ownerTextView: textView, anchorLocation: 0)
        table.frame = NSRect(x: 0, y: 100, width: 400, height: 100)
        textView.addSubview(table)
        table.horizontalOffset = 600
        document.contentView.scroll(to: NSPoint(x: 0, y: 500))
        document.reflectScrolledClipView(document.contentView)
        return Fixture(window: window, document: document, table: table)
    }

    /// Feeds `events` to the table at trackpad cadence, the run loop turning.
    private func send(_ events: [() -> NSEvent], to table: WideTableOverlay) {
        for make in events {
            table.scrollWheel(with: make())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.008))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }

    @Test("A horizontal flick goes to the table from touch down to the end of its momentum")
    func horizontalFlick() {
        let f = makeFixture()
        defer { f.window.orderOut(nil) }
        let live = LiveScrollCounter(f.table)

        send(Self.flick(dx: -10), to: f.table)

        #expect(f.document.received.isEmpty)
        #expect(f.table.horizontalOffset > 600)
        // The table saw the gesture through to its end.
        #expect(live.started == 1)
        #expect(live.ended == 1)
    }

    @Test("A vertical flick over the table goes to the document, touch down and momentum included")
    func verticalFlick() {
        let f = makeFixture()
        defer { f.window.orderOut(nil) }
        let events = Self.flick(dy: -10)

        send(events, to: f.table)

        #expect(f.document.received.count == events.count)
        #expect(f.document.received.first?.phase == .mayBegin)
        #expect(f.document.received.last?.momentumPhase == .ended)
        #expect(f.table.horizontalOffset == 600)
    }

    @Test("A gesture that turns sideways keeps going to the side it started on")
    func diagonalStaysWithFirstMovement() {
        let f = makeFixture()
        defer { f.window.orderOut(nil) }
        var events: [() -> NSEvent] = [{ Self.event(phase: 128) }, { Self.event(dy: -10, phase: 1) }]
        for _ in 0..<5 { events.append { Self.event(dx: -10, phase: 2) } }
        events.append { Self.event(phase: 4) }

        send(events, to: f.table)

        #expect(f.document.received.count == events.count)
        #expect(f.table.horizontalOffset == 600)
    }

    @Test("A touch that never moves goes to the document")
    func touchWithoutMovement() {
        let f = makeFixture()
        defer { f.window.orderOut(nil) }

        send([{ Self.event(phase: 128) }, { Self.event(phase: 8) }], to: f.table)

        #expect(f.document.received.map(\.phase) == [.mayBegin, .cancelled])
    }

    @Test("A mouse wheel goes notch by notch: sideways to the table, up and down to the document")
    func mouseWheel() {
        let f = makeFixture()
        defer { f.window.orderOut(nil) }

        send([{ Self.event(dx: -3, continuous: false) }], to: f.table)
        #expect(f.document.received.isEmpty)
        #expect(f.table.horizontalOffset > 600)

        send([{ Self.event(dy: -3, continuous: false) }], to: f.table)
        #expect(f.document.received.count == 1)
    }
}
