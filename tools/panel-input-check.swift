import Cocoa
import SwiftUI
import ApplicationServices

// Only linked into the isolated lifecycle tool. Geometry markers never handle input.
private final class LifecycleWeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}
private final class LifecyclePassiveTarget: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct LifecycleInputTarget: NSViewRepresentable {
    let id: String
    private static var views: [String: [LifecycleWeakView]] = [:]
    func makeNSView(context: Context) -> NSView {
        let view = LifecyclePassiveTarget()
        Self.views[id, default: []].append(LifecycleWeakView(view))
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        Self.views[id] = (Self.views[id] ?? []).filter { $0.view != nil }
        if !(Self.views[id] ?? []).contains(where: { $0.view === view }) {
            Self.views[id, default: []].append(LifecycleWeakView(view))
        }
    }
    static func target(_ id: String, window: NSWindow) -> NSView? {
        views[id]?.compactMap { $0.view }.last { $0.window === window && $0.superview != nil }
    }
    static func info(in window: NSWindow) -> NSView? {
        views.keys.filter { $0.hasPrefix("info.") }.compactMap { target($0, window: window) }
            .filter { view in
                let rect = view.convert(view.bounds, to: nil)
                return rect.width > 0 && rect.height > 0 &&
                    NSRect(origin: .zero, size: window.contentView?.bounds.size ?? .zero).contains(rect)
            }.max { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY }
    }
}

enum PanelInputCheck {
    private static func write(_ value: [String: Any], _ path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    private static func read(_ path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return row
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private static func wait(_ timeout: Double = 2, host: NSView? = nil, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            pump(0.03, host: host)
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }
    private static func key(_ text: String, window: NSWindow, keyCode: UInt16 = 0,
                            modifiers: NSEvent.ModifierFlags = []) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: keyCode) else { continue }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        pump(0.08)
    }
    private static func click(_ view: NSView, xOffset: CGFloat = 0) -> Bool {
        guard let window = view.window else { return false }
        let rect = view.convert(view.bounds, to: nil)
        let point = NSPoint(x: rect.midX + xOffset, y: rect.midY)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { return false }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        pump(0.18)
        return true
    }
    private static func pidText(_ text: String, pid: pid_t) -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return false }
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            event.postToPid(pid)
        }
        return true
    }
    private static func capture(_ host: NSView?, path: String) {
        guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // Separate controlled receiver. It never loads AppDelegate, collectors or production defaults.
    static func receiver(directory: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) { _exit(3) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VibeDeck isolated input receiver"
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 12, y: 12, width: 376, height: 136))
        field.isRichText = false
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        var lastCommand = ""
        let until = Date().addingTimeInterval(32)
        while Date() < until {
            pump(0.04)
            let command = (try? String(contentsOfFile: directory + "/receiver-command.txt")) ?? ""
            if command != lastCommand {
                lastCommand = command
                if command.hasPrefix("reset") { field.string = "" }
                if command.hasPrefix("yield:"), let targetPID = Int32(command.split(separator: ":")[1]),
                   let target = NSRunningApplication(processIdentifier: targetPID) {
                    app.yieldActivation(to: target)
                    try? command.write(toFile: directory + "/receiver-yield-ack.txt", atomically: true, encoding: .utf8)
                }
                if command.hasPrefix("stop") { break }
            }
            write(["pid": ProcessInfo.processInfo.processIdentifier, "text": field.string,
                   "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                   "isKey": window.isKeyWindow, "firstResponderIsText": window.firstResponder === field, "ready": true], directory + "/receiver.json")
        }
        window.orderOut(nil); window.close()
    }

    static func run(output: String, language: String, scale: Double, report: ScanReport) -> Bool {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            fputs("Popover/input fixture exceeded its 45-second process watchdog\n", stderr); _exit(3)
        }
        let app = NSApplication.shared
        let originalFront = NSWorkspace.shared.frontmostApplication
        let delegate = AppDelegate()
        delegate.lifecyclePrepare(report)
        // Forward the actual OS notification without installing the production launch delegate.
        var resignCount = 0
        let resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: app, queue: .main) {
                resignCount += 1
                delegate.applicationDidResignActive($0)
            }
        func activateControlled(_ target: NSRunningApplication?) {
            guard let target else { return }
            if app.isActive {
                app.yieldActivation(to: target)
                target.activate(from: .current, options: [])
            } else { target.activate(options: []) }
        }
        var failures: [String] = []
        var incomplete: [String] = []
        var rows: [[String: Any]] = []
        func check(_ value: Bool, _ name: String, _ data: [String: Any] = [:]) {
            rows.append(data.merging(["case": name, "passed": value]) { _, new in new })
            print(value ? "PASS \(name)" : "FAIL \(name)")
            if !value { failures.append(name) }
        }
        func closed(_ name: String) {
            _ = wait { !delegate.lifecyclePopoverShown }
            check(!delegate.lifecycleVisible && !delegate.lifecycleContentPresent &&
                  delegate.lifecycleHost == nil && delegate.lifecycleMonitorCount == 0, name,
                  ["visible": delegate.lifecycleVisible, "controller": delegate.lifecycleContentPresent,
                   "monitors": delegate.lifecycleMonitorCount])
            LifecycleHooks.releaseBindings()
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--input-receiver", output]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        var childStarted = false
        defer {
            delegate.lifecycleClose()
            NotificationCenter.default.removeObserver(resign)
            if childStarted && child.isRunning { child.terminate() }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front == ProcessInfo.processInfo.processIdentifier || (childStarted && front == child.processIdentifier) {
                activateControlled(originalFront)
            }
        }
        do { try child.run(); childStarted = true }
        catch { failures.append("receiver could not start: \(error)") }
        let receiverReady = childStarted && wait(3) {
            let state = read(output + "/receiver.json")
            return state["ready"] as? Bool == true && (state["pid"] as? Int) == Int(child.processIdentifier)
        }
        check(receiverReady, "controlled-receiver-ready")
        let receiverApp = childStarted ? NSRunningApplication(processIdentifier: child.processIdentifier) : nil
        activateControlled(receiverApp)
        let receiverFocused = childStarted && wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier }
        check(receiverFocused, "receiver-focused-before-popover")

        var yieldSequence = 0
        func openWithControlledActivation() -> NSView {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier {
                yieldSequence += 1
                let command = "yield:\(ProcessInfo.processInfo.processIdentifier):\(yieldSequence)"
                try? command.write(toFile: output + "/receiver-command.txt", atomically: true, encoding: .utf8)
                _ = wait { (try? String(contentsOfFile: output + "/receiver-yield-ack.txt")) == command }
            }
            return delegate.lifecycleOpen()
        }
        // The controlled receiver grants activation, equivalent to permission supplied by a user click.
        // Prove shortcuts traverse the real local monitor, then native search editing.
        if let host = openWithControlledActivation() as NSView?, let window = host.window {
            pump(0.35, host: host)
            check(delegate.lifecyclePopoverShown && delegate.lifecycleMonitorCount == 2,
                  "real-transient-popover-open", ["windowClass": String(describing: type(of: window)), "monitors": delegate.lifecycleMonitorCount])
            let panelFocusedBeforeInput = wait {
                app.isActive && window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            }
            check(panelFocusedBeforeInput, "parent-front-and-popover-key-before-input")
            key("3", window: window, keyCode: 20, modifiers: .command)
            check(LifecycleHooks.tab?.wrappedValue == 2, "native-command-shortcut-through-monitor")
            LifecycleHooks.detail?.wrappedValue = DashboardView.pricesPage
            pump(0.3, host: host)
            let search = descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable }
            if let search {
                window.makeKey(); window.makeFirstResponder(search)
                key("g", window: window); key("p", window: window); key("t", window: window)
                let editorFocused = wait {
                    search.currentEditor() != nil && search.currentEditor() === window.firstResponder &&
                    window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                }
                let posted = editorFocused && pidText("中文", pid: ProcessInfo.processInfo.processIdentifier)
                let received = wait { search.stringValue == "gpt中文" }
                check(editorFocused && posted && received, "native-price-search-English-and-Unicode-Chinese",
                      ["text": search.stringValue, "fieldEditorFocused": editorFocused,
                       "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
                capture(host, path: output + "/input-prices.png")
            } else { check(false, "native-price-search-field-found") }
            key("\u{1b}", window: window, keyCode: 53)
            closed("Escape-clears-popover-and-monitors")
            let restoredWithoutActivation = childStarted && wait {
                let state = read(output + "/receiver.json")
                return NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier &&
                    state["isKey"] as? Bool == true && state["firstResponderIsText"] as? Bool == true
            }
            check(receiverFocused && panelFocusedBeforeInput && restoredWithoutActivation, "Escape-restores-prior-receiver-without-reactivation",
                  ["frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                   "receiverPID": childStarted ? child.processIdentifier : -1,
                   "receiverIsKey": read(output + "/receiver.json")["isKey"] ?? false,
                   "receiverFirstResponderIsText": read(output + "/receiver.json")["firstResponderIsText"] ?? false])
            if restoredWithoutActivation && CGPreflightPostEventAccess() {
                let posted = pidText("after-Esc 中文", pid: child.processIdentifier)
                let received = wait { (read(output + "/receiver.json")["text"] as? String ?? "").contains("after-Esc 中文") }
                check(posted && received, "immediate-PID-directed-input-after-Escape",
                      ["receiverText": read(output + "/receiver.json")["text"] ?? ""])
            } else {
                incomplete.append("PID-directed post-Escape receiver text: event-post permission or restored focus unavailable")
            }
        } else { check(false, "popover-host-window-found") }

        // Open a real info Button's nested SwiftUI popover, then close the parent.
        autoreleasepool {
            let host = openWithControlledActivation(); pump(0.25, host: host)
            LifecycleHooks.detail?.wrappedValue = nil
            LifecycleHooks.tab?.wrappedValue = 0
            pump(0.2, host: host)
            if let window = host.window, let info = LifecycleInputTarget.info(in: window) {
                let before = Set(app.windows.filter(\.isVisible).map(\.windowNumber))
                let clicked = click(info)
                let nested = app.windows.filter { $0.isVisible && !before.contains($0.windowNumber) }
                check(clicked && !nested.isEmpty && delegate.lifecyclePopoverShown, "native-info-nested-popover-open",
                      ["newWindowClasses": nested.map { String(describing: type(of: $0)) }])
                delegate.lifecycleClose(); pump(0.2)
                closed("parent-close-dismisses-info-and-monitors")
                check(nested.allSatisfy { !$0.isVisible }, "nested-info-window-dismissed")
            } else { check(false, "native-info-Button-target-found"); delegate.lifecycleClose(); closed("close-after-info-target-missing") }
        }

        // A click in another controlled window must close transient popover, not grab input.
        let outside = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 120),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false; outside.title = "VibeDeck own-window input receiver"
        let text = NSTextView(frame: NSRect(x: 10, y: 10, width: 340, height: 100))
        text.isRichText = false; outside.contentView?.addSubview(text)
        outside.orderFront(nil)
        _ = openWithControlledActivation()
        _ = wait { app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
        _ = click(text)
        outside.makeKeyAndOrderFront(nil); outside.makeFirstResponder(text)
        pump(0.2)
        check(!delegate.lifecyclePopoverShown, "outside-own-window-click-dismisses-popover")
        let outsideFocused = wait {
            outside.isKeyWindow && outside.firstResponder === text &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }
        let outsidePosted = outsideFocused && pidText("outside 中文", pid: ProcessInfo.processInfo.processIdentifier)
        let outsideReceived = wait { text.string.contains("outside 中文") }
        check(outsideFocused && outsidePosted && outsideReceived, "outside-own-window-English-and-Unicode-input",
              ["text": text.string, "receiverFocused": outsideFocused,
               "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
        delegate.lifecycleClose(); closed("outside-window-no-residual-monitors")
        outside.orderOut(nil); outside.close()

        // Actual cross-process focus transfer; no physical CmdTab or user window is targeted.
        _ = openWithControlledActivation()
        let parentFocusedBeforeSwitch = wait {
            app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }
        let frontBeforeSwitch = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        activateControlled(receiverApp)
        let switched = childStarted && wait {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier && !delegate.lifecyclePopoverShown
        }
        check(parentFocusedBeforeSwitch && switched, "switch-to-controlled-app-dismisses-popover",
              ["parentFocusedBeforeSwitch": parentFocusedBeforeSwitch, "frontBeforeSwitch": frontBeforeSwitch,
               "frontAfterSwitch": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
               "receiverPID": childStarted ? child.processIdentifier : -1, "realResignNotificationCount": resignCount])
        closed("application-resign-no-residual-monitors")
        if switched && CGPreflightPostEventAccess() {
            let posted = pidText(" switched 中文", pid: child.processIdentifier)
            let received = wait { (read(output + "/receiver.json")["text"] as? String ?? "").contains("switched 中文") }
            check(posted && received, "input-after-controlled-app-switch", ["receiverText": read(output + "/receiver.json")["text"] ?? ""])
        } else { incomplete.append("Cross-app PID-directed text not executed: unavailable focus/event-post permission") }

        // Stress real layout invalidation and observe stderr/unified logs for this PID.
        for round in 0..<3 {
            autoreleasepool {
                let host = openWithControlledActivation(); pump(0.15, host: host)
                LifecycleHooks.tab?.wrappedValue = 2
                pump(0.35, host: host)
                LifecycleHooks.device?.wrappedValue = round == 1 ? "remote:fixture-single" : "all"
                pump(0.35, host: host)
                if let window = host.window, let disclosure = LifecycleInputTarget.target("stats.history", window: window) {
                    if let scroll = scrollView(host), let document = scroll.documentView {
                        _ = document.scrollToVisible(disclosure.convert(disclosure.bounds, to: document))
                        scroll.reflectScrolledClipView(scroll.contentView); pump(0.1, host: host)
                    }
                    _ = click(disclosure)
                    pump(0.35, host: host)
                }
                LifecycleHooks.detail?.wrappedValue = DashboardView.settingsPage
                pump(0.2, host: host)
                if let window = host.window,
                   let target = LifecycleInputTarget.target(round == 1 ? "settings.font.0.85" : "settings.font.1.3", window: window) {
                    _ = click(target); pump(0.35, host: host)
                }
                check(delegate.lifecycleMonitorCount == 2, "one-monitor-pair-during-layout-round-\(round)")
                delegate.lifecycleClose(); closed("repeated-close-round-\(round)")
            }
        }

        // Replace only snapshot's hardware boundary; test the actual production async gate.
        LifecycleHooks.fanLock.lock(); LifecycleHooks.fanBlocked = true
        let fanBefore = LifecycleHooks.fanCalls; LifecycleHooks.fanLock.unlock()
        var completionOnMain = false
        var completed = false
        let accepted = FanControl.shared.readSnapshot { _ in completionOnMain = Thread.isMainThread; completed = true }
        _ = wait { LifecycleHooks.fanLock.lock(); defer { LifecycleHooks.fanLock.unlock() }; return LifecycleHooks.fanCalls > fanBefore }
        let rejected = (0..<20).filter { _ in !FanControl.shared.readSnapshot { _ in } }.count
        var mainHeartbeat = false
        DispatchQueue.main.async { mainHeartbeat = true }
        pump(0.2)
        check(accepted && rejected == 20 && mainHeartbeat && !completed && !LifecycleHooks.fanOnMain,
              "blocked-SMC-boundary-single-flight-and-main-runnable", ["rejectedConcurrentReads": rejected, "mainHeartbeat": mainHeartbeat, "snapshotOnMain": LifecycleHooks.fanOnMain])
        LifecycleHooks.fanGate.signal()
        _ = wait { completed }
        check(completed && completionOnMain, "fan-completion-delivered-on-main")
        LifecycleHooks.fanLock.lock(); LifecycleHooks.fanBlocked = false; LifecycleHooks.fanLock.unlock()

        let valid = failures.isEmpty && incomplete.isEmpty
        let result: [String: Any] = ["valid": valid, "pid": ProcessInfo.processInfo.processIdentifier,
            "language": language, "scale": scale, "host": "actual production transient NSPopover; no NSMenu tracking",
            "rows": rows, "failures": failures, "incomplete": incomplete,
            "scope": "Copied production lifecycle and monitor code; in-memory defaults, empty home, no collectors or real SMC access. Native queued NSEvents and PID-directed CGEvents when permitted. Unicode Chinese input is not real IME composition. Physical CmdTab and original hang reproduction are not claimed.",
            "cycleAuditRequired": "Inspect this fixture PID's stderr and unified log for AttributeGraph Cycle detected; geometry alone is not a pass." ]
        write(result, output + "/popover-input-\(language.hasPrefix("zh") ? "zh" : "en").json")
        print(valid ? "PASS popover/input" : "PARTIAL/FAIL popover/input; see JSON")
        return valid
    }
}
