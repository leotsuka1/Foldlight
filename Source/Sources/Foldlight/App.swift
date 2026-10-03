import AppKit
import SwiftUI
import MetalKit
import QuartzCore

final class FoldController: NSObject, ObservableObject {
    @Published var angle: Double?
    @Published var permission = CGPreflightScreenCaptureAccess()
    @Published var message = ""
    @Published var previewing = false
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); if !enabled { hide() } }
    }
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }
    @Published var softness: Double {
        didSet { UserDefaults.standard.set(softness, forKey: "softness") }
    }
    let renderer = FoldRenderer()
    let capture = ScreenCapture()
    private let sensor = LidSensor()
    private var overlay: OverlayWindow?
    private var timer: Timer?
    private var displayLink: CADisplayLink?
    private var nextSensorRead = 0.0
    private var reading = false
    private var lastReading = ProcessInfo.processInfo.systemUptime
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var previewStart: Double?
    private var displayID: CGDirectDisplayID?
    private var transition = false
    private var captureStarted: Double?
    private var smoothed = 0.0
    private var motion = FoldMotion()
    private var sleeping = false
    private var warmUntil = 0.0
    private var nextPermissionCheck = 0.0
    private var presentationTime = 0.0
    private var firstDesktopFrame = false
    private var needsCaptureRestart = false
    private var lastClosingMovement = 0.0

    override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "enabled") == nil ? true : defaults.bool(forKey: "enabled")
        threshold = defaults.object(forKey: "threshold") == nil ? 100 : min(125, max(65, defaults.double(forKey: "threshold")))
        softness = defaults.object(forKey: "softness") == nil ? 0.85 : min(1.5, max(0, defaults.double(forKey: "softness")))
        super.init()
        capture.onFailure = { [weak self] error in
            guard let self else { return }
            self.message = "Screen capture stopped: \(error)"; self.enabled = false; self.hide()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true; self?.hide(); self?.previewStart = nil; self?.previewing = false
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide(); self?.overlay?.close(); self?.overlay = nil; self?.displayID = nil
            self?.previewStart = nil; self?.previewing = false
            self?.needsCaptureRestart = true; self?.firstDesktopFrame = false
            self?.displayLink?.invalidate(); self?.displayLink = nil
        }
        timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self, self.displayLink?.isPaused != false else { return }
            self.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(value.uint32Value) != 0
        }
    }

    private func prepareOverlay() -> Bool {
        guard let screen = builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            message = "Connect or open the built-in MacBook display."; return false
        }
        if overlay == nil {
            overlay = OverlayWindow(screen: screen, renderer: renderer); displayID = number.uint32Value
            let link = screen.displayLink(target: self, selector: #selector(displayFrame(_:)))
            let maximum = Float(screen.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.isPaused = true; link.add(to: .main, forMode: .common); displayLink = link
        }
        return true
    }

    private func hide() {
        overlay?.orderOut(nil); smoothed = 0; motion.reset(); renderer.progress = 0
        presentationTime = 0
        displayLink?.isPaused = true
    }

    func preview() {
        guard !previewing, prepareOverlay() else { return }
        message = ""
        renderer.texture = DemoDesktop.texture(device: renderer.device)
        previewStart = ProcessInfo.processInfo.systemUptime
        previewing = true
    }

    func stopPreview() {
        previewStart = nil; previewing = false; renderer.texture = nil; hide()
    }

    func requestPermission() {
        if CGPreflightScreenCaptureAccess() { permission = true; message = ""; return }
        permission = CGRequestScreenCaptureAccess()
        if !permission {
            message = "Allow Foldlight in Screen & System Audio Recording, then quit and reopen the app if macOS asks."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func setCapture(wanted: Bool, now: Double) {
        guard !transition else { return }
        if wanted && !capture.running, let displayID, let overlay {
            let windowID = overlay.registerForCapture()
            transition = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.transition = false }
                do {
                    try await self.capture.start(displayID: displayID, excludingWindowIDs: [windowID])
                    self.captureStarted = ProcessInfo.processInfo.systemUptime
                } catch {
                    self.message = "Unable to start desktop folding. \(error.localizedDescription)"
                    self.enabled = false; self.hide()
                }
            }
        } else if !wanted && capture.running {
            transition = true; captureStarted = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.capture.stop(); self.transition = false
                if !self.previewing { self.renderer.texture = nil }
            }
        }
    }

    @objc private func displayFrame(_ link: CADisplayLink) { tick() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.1, now - lastTick); lastTick = now
        if !reading && !sleeping && now >= nextSensorRead {
            reading = true
            nextSensorRead = now + 1 / 60
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let self else { return }
                let value = self.sensor.angle()
                DispatchQueue.main.async {
                    self.reading = false
                    if let value {
                        let timestamp = ProcessInfo.processInfo.systemUptime
                        if let previous = self.angle, value < previous - 0.25 { self.lastClosingMovement = timestamp }
                        if self.angle != value { self.angle = value }
                        self.lastReading = timestamp
                    }
                    else if ProcessInfo.processInfo.systemUptime - self.lastReading > 0.5 { self.angle = nil }
                }
            }
        }
        if now >= nextPermissionCheck { permission = CGPreflightScreenCaptureAccess(); nextPermissionCheck = now + 1 }
        if sleeping { hide(); setCapture(wanted: false, now: now); return }
        if needsCaptureRestart {
            hide(); setCapture(wanted: false, now: now)
            if !capture.running && !transition { needsCaptureRestart = false }
            return
        }
        if let start = previewStart {
            let t = now - start
            if t >= FoldMotion.previewDuration { stopPreview(); return }
            renderer.progress = Float(FoldMotion.preview(at: t)); renderer.softness = Float(softness)
            displayLink?.isPaused = false
            overlay?.reveal()
            overlay?.redraw()
            setCapture(wanted: false, now: now)
            return
        }
        guard enabled, permission, prepareOverlay() else {
            hide(); setCapture(wanted: false, now: now); return
        }
        let target = angle.map { FoldMath.progress(angle: $0, threshold: threshold) } ?? 0
        if let angle, angle < threshold || (angle < threshold + 18 && now - lastClosingMovement < 0.5) {
            warmUntil = now + 0.65
        }
        let wanted = now < warmUntil || smoothed > 0.0001
        displayLink?.isPaused = !wanted
        setCapture(wanted: wanted, now: now)
        if let frame = capture.latest() { renderer.update(frame) }
        if capture.running, capture.latest() == nil, let started = captureStarted, now - started > 3 {
            message = "No desktop frames arrived. Check screen recording access and reopen Foldlight."
            enabled = false; hide(); return
        }
        let hasFrame = capture.running && capture.latest() != nil
        if hasFrame && !firstDesktopFrame { motion.reset(); presentationTime = now; firstDesktopFrame = true }
        if !hasFrame { firstDesktopFrame = false }
        smoothed = motion.advance(to: hasFrame ? target : 0, delta: delta)
        // Keep an asynchronous capture startup from appearing as a sudden crease.
        let arrival = min(1, max(0, (now - presentationTime) / 0.16))
        let ease = arrival * arrival * (3 - 2 * arrival)
        renderer.progress = Float(smoothed * ease); renderer.softness = Float(softness)
        if smoothed > 0.0001 && hasFrame {
            overlay?.reveal()
            overlay?.redraw()
        } else if capture.running || !transition { overlay?.orderOut(nil) }
    }

    func shutdown() { timer?.invalidate(); displayLink?.invalidate(); stopPreview(); overlay?.close() }
}

struct SettingsView: View {
    @ObservedObject var controller: FoldController
    private let mint = Color(red: 0.64, green: 0.95, blue: 0.80)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer").font(.system(size: 29, weight: .light))
                    .foregroundStyle(mint).frame(width: 58, height: 58)
                    .background(mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Foldlight").font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("A little motion for your Mac.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 13) {
                Image(systemName: "macbook").font(.system(size: 62, weight: .ultraLight))
                    .foregroundStyle(mint.opacity(0.85)).padding(.top, 8)
                HStack(spacing: 8) {
                    Circle().fill(controller.angle == nil ? Color.orange : mint).frame(width: 6, height: 6)
                    Text(controller.angle.map { "Lid sensor · \(Int($0))°" } ?? "Lid sensor unavailable")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button(controller.previewing ? "Stop preview" : "Preview the fold") {
                    if controller.previewing { controller.stopPreview() } else { controller.preview() }
                }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                Text("Preview uses a sample desktop.").font(.caption2).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity).padding(18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            Toggle("Respond to the lid", isOn: $controller.enabled).tint(mint)
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("Start folding below"); Spacer(); Text("\(Int(controller.threshold))°").monospacedDigit().foregroundStyle(mint) }
                Slider(value: $controller.threshold, in: 65...125, step: 1).tint(mint)
                Text("Keep this below your usual working angle.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("Softness"); Spacer(); Text(controller.softness == 0 ? "Clear" : "\(Int(controller.softness / 1.5 * 100))%").foregroundStyle(mint) }
                Slider(value: $controller.softness, in: 0...1.5).tint(mint)
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: controller.permission ? "checkmark.shield" : "rectangle.on.rectangle")
                    .foregroundStyle(controller.permission ? mint : .secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.permission ? "Screen access is ready" : "Allow screen recording to fold your desktop").font(.system(size: 12, weight: .medium))
                    Text("Desktop frames stay in memory on this Mac. No audio, files, or uploads.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !controller.permission {
                        Button("Allow screen recording…") { controller.requestPermission() }.padding(.top, 4)
                    }
                }
            }
            if !controller.message.isEmpty {
                Text(controller.message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Click the menu bar icon to pause or quit. Your Mac sleeps normally when closed.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(width: 420).background(Color(red: 0.065, green: 0.08, blue: 0.085))
            .preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: FoldController!
    private var item: NSStatusItem!
    private var settings: NSWindow?
    private var localKeys: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = FoldController()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Foldlight")
        item.button?.toolTip = "Foldlight — desktop folding"
        item.button?.target = self; item.button?.action = #selector(showMenu)
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && self?.controller.previewing == true { self?.controller.stopPreview(); return nil }
            return event
        }
        showSettings()
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Foldlight", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        let sensor = NSMenuItem(title: controller.angle.map { "Lid: \(Int($0))°" } ?? "Lid sensor unavailable", action: nil, keyEquivalent: "")
        sensor.isEnabled = false; menu.addItem(sensor); menu.addItem(.separator())
        add(menu, controller.enabled ? "Pause lid effect" : "Enable lid effect", #selector(toggle))
        add(menu, controller.previewing ? "Stop preview" : "Preview fold", #selector(preview))
        add(menu, "Settings…", #selector(showSettings), key: ",")
        menu.addItem(.separator()); add(menu, "Quit Foldlight", #selector(quit), key: "q")
        item.menu = menu; item.button?.performClick(nil); item.menu = nil
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
    }
    @objc private func toggle() { controller.enabled.toggle() }
    @objc private func preview() { controller.previewing ? controller.stopPreview() : controller.preview() }
    @objc func showSettings() {
        if settings == nil {
            let view = NSHostingView(rootView: SettingsView(controller: controller))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Foldlight"; window.contentView = view; window.isReleasedWhenClosed = false
            window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown(); if let localKeys { NSEvent.removeMonitor(localKeys) }
    }
}

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--capture-regression") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try await CaptureRegression.run(); exit(0) }
                catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try Validation.run() }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--sensor-check") {
            if let angle = LidSensor().angle() { print("Lid sensor available: \(angle)°") }
            else { print("No readable lid-angle sensor."); exit(2) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--export-preview"), CommandLine.arguments.count > index + 1 {
            do { try PreviewMovie.export(to: CommandLine.arguments[index + 1]) }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-check"), CommandLine.arguments.count > index + 1 {
            do { try DemoDesktop.renderCheck(to: CommandLine.arguments[index + 1]) }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
