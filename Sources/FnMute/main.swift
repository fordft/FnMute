import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import IOKit.hid
import ServiceManagement

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

// Quartz flags can be cleared by dictation apps while the physical Fn key is held.
// This is diagnostic only: it must never determine when sound is restored.
func quartzFnIsDown() -> Bool {
    CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
}

final class PhysicalFnMonitor {
    private var manager: IOHIDManager?
    private var devices: [UInt64: String] = [:]
    private var state = PhysicalFnState()
    private(set) var permissionGranted = CGPreflightListenEventAccess()
    private(set) var openError: String?
    var onChange: (() -> Void)?
    var isDown: Bool { state.isDown }
    var keyboardCount: Int { devices.count }
    var errorMessage: String? {
        if !permissionGranted { return "Enable Input Monitoring for Fn Mute" }
        if let openError { return openError }
        if devices.isEmpty { return "No physical keyboard with a Fn key is connected" }
        return nil
    }

    static func registryID(_ device: IOHIDDevice) -> UInt64 {
        var identifier: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &identifier)
        return identifier
    }

    static func isPhysical(_ device: IOHIDDevice) -> Bool {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        return !transport.localizedCaseInsensitiveContains("virtual")
            && !product.localizedCaseInsensitiveContains("virtual")
            && !product.localizedCaseInsensitiveContains("karabiner")
    }

    func refreshAccess() {
        let granted = CGPreflightListenEventAccess()
        if !granted {
            if manager != nil { stop() }
            permissionGranted = false
            return
        }
        permissionGranted = true
        if manager == nil { start() }
    }

    private func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let keyboard: [String: Any] = [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6]
        IOHIDManagerSetDeviceMatching(manager, keyboard as CFDictionary)
        let fnElements: [[String: Any]] = [0xff, 0xff01].map {
            [kIOHIDElementUsagePageKey: $0, kIOHIDElementUsageKey: 3]
        }
        // The HID queue contains only Fn values. Other keys never reach our callback.
        IOHIDManagerSetInputValueMatchingMultiple(manager, fnElements as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<PhysicalFnMonitor>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<PhysicalFnMonitor>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<PhysicalFnMonitor>.fromOpaque(context).takeUnretainedValue()
            let id = PhysicalFnMonitor.registryID(device)
            monitor.devices.removeValue(forKey: id)
            monitor.state.remove(device: id)
            monitor.onChange?()
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, 0) // Shared access; never seize the keyboard.
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
            openError = "Could not read physical Fn (\(result)); reopen Fn Mute"
            return
        }
        self.manager = manager
        openError = nil
        for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] { attach(device) }
    }

    private func attach(_ device: IOHIDDevice) {
        guard Self.isPhysical(device) else { return }
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
        let fnElements = elements.filter {
            PhysicalFnState.isFn(page: IOHIDElementGetUsagePage($0), usage: IOHIDElementGetUsage($0))
                && IOHIDElementGetType($0) != kIOHIDElementTypeCollection
        }
        guard !fnElements.isEmpty else { return }
        let id = Self.registryID(device)
        guard devices[id] == nil else { return }
        devices[id] = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Keyboard"
        for element in fnElements {
            let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            if IOHIDDeviceGetValue(device, element, value) == kIOReturnSuccess {
                receive(value.pointee.takeUnretainedValue())
            }
            value.deallocate()
        }
        onChange?()
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard Self.isPhysical(device) else { return }
        let before = state.isDown
        state.receive(device: Self.registryID(device), cookie: IOHIDElementGetCookie(element),
            page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element),
            down: IOHIDValueGetIntegerValue(value) != 0, physical: true)
        if state.isDown != before { onChange?() }
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
        devices.removeAll()
        state.clear()
    }
}

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SavedControl: Codable, Equatable {
    let deviceUID: String
    let deviceName: String
    let selector: UInt32
    let element: UInt32
    let original: Double
    var mutedValue: Double { selector == kAudioDevicePropertyMute ? 1 : 0 }
}

enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress,
                        initial: T) throws -> T {
        var property = property
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw AudioFailure(message: "Could not read audio setting (\(status)).")
        }
        return value
    }

    static func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress,
                         value: T) throws {
        var property = property
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else {
            throw AudioFailure(message: "Could not change audio setting (\(status)).")
        }
    }

    static func canWrite(_ device: AudioDeviceID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &property)
            && AudioObjectIsPropertySettable(device, &property, &settable) == noErr
            && settable.boolValue
    }

    static func text(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        let property = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        let value: CFString = try read(device, property, initial: "" as CFString)
        return value as String
    }

    static func devices() throws -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else {
            throw AudioFailure(message: "Could not list audio outputs.")
        }
        var result = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw AudioFailure(message: "Could not list audio outputs.") }
        return result
    }

    static func activeOutputs() throws -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output: UInt32 = try read(system,
            address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal),
            initial: UInt32(0))
        let alerts: UInt32 = try read(system,
            address(kAudioHardwarePropertyDefaultSystemOutputDevice, scope: kAudioObjectPropertyScopeGlobal),
            initial: UInt32(0))
        return Array(Set([output, alerts].filter { $0 != kAudioObjectUnknown })).sorted()
    }

    static func channelCount(_ device: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
        guard status == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, pointer) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    static func capture(_ device: AudioDeviceID) throws -> [SavedControl] {
        let uid = try text(device, selector: kAudioDevicePropertyDeviceUID)
        let name = (try? text(device, selector: kAudioObjectPropertyName)) ?? "Audio output"
        let mute = address(kAudioDevicePropertyMute)
        if canWrite(device, mute) {
            let original: UInt32 = try read(device, mute, initial: UInt32(0))
            return [SavedControl(deviceUID: uid, deviceName: name,
                selector: kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain,
                original: Double(original))]
        }
        let volume = address(kAudioDevicePropertyVolumeScalar)
        if canWrite(device, volume) {
            let original: Float32 = try read(device, volume, initial: Float32(0))
            return [SavedControl(deviceUID: uid, deviceName: name,
                selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain,
                original: Double(original))]
        }
        let channels = try channelCount(device)
        guard channels > 0, channels <= 128 else {
            throw AudioFailure(message: "\(name) does not support system mute or volume.")
        }
        // A per-channel fallback is used only if every output channel is controllable.
        let selector: UInt32
        if (1...channels).allSatisfy({ canWrite(device, address(kAudioDevicePropertyMute, element: $0)) }) {
            selector = kAudioDevicePropertyMute
        } else if (1...channels).allSatisfy({ canWrite(device, address(kAudioDevicePropertyVolumeScalar, element: $0)) }) {
            selector = kAudioDevicePropertyVolumeScalar
        } else {
            throw AudioFailure(message: "\(name) does not support system mute or volume.")
        }
        return try (1...channels).map { channel in
            let property = address(selector, element: channel)
            let original: Double
            if selector == kAudioDevicePropertyMute {
                original = Double(try read(device, property, initial: UInt32(0)))
            } else {
                original = Double(try read(device, property, initial: Float32(0)))
            }
            return SavedControl(deviceUID: uid, deviceName: name, selector: selector,
                element: channel, original: original)
        }
    }

    static func device(for uid: String, in devices: [AudioDeviceID]) -> AudioDeviceID? {
        devices.first { (try? text($0, selector: kAudioDevicePropertyDeviceUID)) == uid }
    }

    static func value(_ device: AudioDeviceID, _ control: SavedControl) throws -> Double {
        let property = address(control.selector, element: control.element)
        if control.selector == kAudioDevicePropertyMute {
            return Double(try read(device, property, initial: UInt32(0)))
        }
        return Double(try read(device, property, initial: Float32(0)))
    }

    static func set(_ device: AudioDeviceID, _ control: SavedControl, value: Double) throws {
        let property = address(control.selector, element: control.element)
        if control.selector == kAudioDevicePropertyMute {
            try write(device, property, value: UInt32(value))
        } else {
            try write(device, property, value: Float32(value))
        }
        let actual = try self.value(device, control)
        guard abs(actual - value) < 0.002 else {
            throw AudioFailure(message: "\(control.deviceName) did not apply its sound setting.")
        }
    }

    static func snapshot() throws -> [SavedControl] {
        try activeOutputs().flatMap { try capture($0) }
    }
}

final class AudioController {
    let directory: URL
    private let journal: URL
    private(set) var saved: [SavedControl]
    private(set) var lastError: String?

    init(directory: URL) throws {
        self.directory = directory
        journal = directory.appendingPathComponent("saved-output.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: journal.path) {
            saved = try JSONDecoder().decode([SavedControl].self, from: Data(contentsOf: journal))
        } else {
            saved = []
        }
    }

    func persist() throws {
        if saved.isEmpty {
            if FileManager.default.fileExists(atPath: journal.path) {
                try FileManager.default.removeItem(at: journal)
            }
        } else {
            try JSONEncoder().encode(saved).write(to: journal, options: .atomic)
        }
    }

    func mute() {
        lastError = nil
        do {
            for device in try AudioHardware.activeOutputs() {
                do {
                    let uid = try AudioHardware.text(device, selector: kAudioDevicePropertyDeviceUID)
                    if !saved.contains(where: { $0.deviceUID == uid }) {
                        let newControls = try AudioHardware.capture(device)
                        let previous = saved
                        saved.append(contentsOf: newControls)
                        do { try persist() } catch { saved = previous; throw error }
                    }
                    for control in saved where control.deviceUID == uid {
                        if abs(try AudioHardware.value(device, control) - control.mutedValue) > 0.001 {
                            try AudioHardware.set(device, control, value: control.mutedValue)
                        }
                    }
                } catch { lastError = error.localizedDescription }
            }
        } catch { lastError = error.localizedDescription }
    }

    func restore() {
        lastError = nil
        guard !saved.isEmpty else { return }
        do {
            let devices = try AudioHardware.devices()
            var remaining: [SavedControl] = []
            for control in saved {
                guard let device = AudioHardware.device(for: control.deviceUID, in: devices) else {
                    // Preserve the setting for recovery if a disconnected output returns later.
                    remaining.append(control)
                    continue
                }
                do { try AudioHardware.set(device, control, value: control.original) }
                catch { remaining.append(control); lastError = error.localizedDescription }
            }
            saved = remaining
            try persist()
        } catch { lastError = error.localizedDescription }
    }

    func log(_ message: String) {
        let url = directory.appendingPathComponent("activity.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let existing = try? Data(contentsOf: url), existing.count < 65_536,
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)) } catch { }
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let audio: AudioController
    let fnMonitor = PhysicalFnMonitor()
    let loginItem = LoginItemController()
    var item: NSStatusItem!
    var statusLine: NSMenuItem!
    var enableItem: NSMenuItem!
    var loginMenuItem: NSMenuItem!
    var loginHelpItem: NSMenuItem!
    var timer: Timer?
    var signals: [DispatchSourceSignal] = []
    var enabled = !UserDefaults.standard.bool(forKey: "paused")
    var held = false
    var suspended = false
    var testingMute = false
    var testGeneration = 0
    var awaitRelease = false
    var lastAudioCheck = Date.distantPast
    var lastReportedError: String?
    var lastInputError: String?
    var lastAccessCheck = Date.distantPast
    var reportedQuartzMismatch = false

    init(audio: AudioController) { self.audio = audio }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        audio.restore()
        audio.log("Started v\(appVersion); observing physical HID Fn press/release.")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusLine = NSMenuItem(title: "Fn Mute — Ready", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(NSMenuItem.separator())
        enableItem = NSMenuItem(title: "Enable Fn muting", action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        menu.addItem(enableItem)
        let permissionItem = NSMenuItem(title: "Open Input Monitoring Settings…", action: #selector(openInputSettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        let testItem = NSMenuItem(title: "Test mute for 2 seconds", action: #selector(testMute), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        let showItem = NSMenuItem(title: "Show app in Finder", action: #selector(showApp), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        loginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        loginHelpItem = NSMenuItem(title: "Open Login Items Settings…", action: #selector(openLoginSettings), keyEquivalent: "")
        loginHelpItem.target = self
        menu.addItem(loginHelpItem)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Fn Mute", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        loginItem.configureDefault()
        updateStatus()

        fnMonitor.onChange = { [weak self] in self?.poll() }
        fnMonitor.refreshAccess()
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        poll()
        if !fnMonitor.permissionGranted && !UserDefaults.standard.bool(forKey: "requestedHardwareFnAccess") {
            UserDefaults.standard.set(true, forKey: "requestedHardwareFnAccess")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "Enable Fn key access"
                alert.informativeText = "Fn Mute needs Input Monitoring to detect when you press and release the physical Fn key. It only observes Fn; it does not collect other keys or audio. Enable Fn Mute in the next settings page. If macOS asks, choose Quit & Reopen."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { self.openInputSettings() }
            }
        }
    }

    @objc func poll() {
        guard !testingMute else { return }
        if Date().timeIntervalSince(lastAccessCheck) > 1 {
            lastAccessCheck = Date()
            fnMonitor.refreshAccess()
        }
        let down = fnMonitor.isDown
        if down && !quartzFnIsDown() && !reportedQuartzMismatch {
            reportedQuartzMismatch = true
            audio.log("Quartz Fn flag cleared while physical Fn is held; keeping output muted.")
        }
        if !down { reportedQuartzMismatch = false }
        if awaitRelease && !down { awaitRelease = false }
        let shouldMute = enabled && !suspended && !awaitRelease && down
        if shouldMute != held {
            held = shouldMute
            if held { audio.mute() } else { audio.restore() }
            lastAudioCheck = Date()
            audio.log(held ? "Physical Fn pressed; output muted." : "Physical Fn released; original sound settings restored.")
            updateStatus()
        } else if Date().timeIntervalSince(lastAudioCheck) > (held ? 0.25 : 2.0) {
            lastAudioCheck = Date()
            if held { audio.mute() }
            else if !audio.saved.isEmpty { audio.restore() }
            if audio.lastError != lastReportedError { updateStatus() }
        }
        if fnMonitor.errorMessage != lastInputError { updateStatus() }
    }

    func updateStatus() {
        guard item != nil else { return }
        lastReportedError = audio.lastError
        lastInputError = fnMonitor.errorMessage
        let symbol = (audio.lastError != nil || fnMonitor.errorMessage != nil) ? "speaker.badge.exclamationmark"
            : (held ? "speaker.slash.fill" : "speaker.wave.2")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fn Mute")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = " Fn"
        let text = audio.lastError ?? (testingMute ? "Testing mute for 2 seconds"
            : (!enabled ? "Paused" : (fnMonitor.errorMessage ?? (held ? "Muted while Fn is held" : "Ready — hold Fn to mute"))))
        item.button?.toolTip = "Fn Mute: \(text)"
        statusLine.title = text
        enableItem.state = enabled ? .on : .off
        loginMenuItem.state = loginItem.isEnabled ? .on : (loginItem.needsApproval ? .mixed : .off)
        loginHelpItem.isHidden = !loginItem.needsApproval && loginItem.errorMessage == nil
        loginHelpItem.toolTip = loginItem.errorMessage ?? "Allow Fn Mute to open at login in System Settings"
        let status: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "version": appVersion, "enabled": enabled, "fnHeld": fnMonitor.isDown,
            "launchAtLogin": loginItem.isEnabled, "loginItemNeedsApproval": loginItem.needsApproval,
            "loginItemError": loginItem.errorMessage ?? "",
            "outputMutedByHelper": held, "suspended": suspended,
            "fnSource": "physical HID", "inputMonitoringGranted": fnMonitor.permissionGranted,
            "physicalFnKeyboards": fnMonitor.keyboardCount, "inputError": fnMonitor.errorMessage ?? "",
            "pendingRestoreControls": audio.saved.count, "error": audio.lastError ?? "",
            "updated": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: audio.directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    @objc func toggleEnabled() {
        testingMute = false
        testGeneration += 1
        enabled.toggle()
        UserDefaults.standard.set(!enabled, forKey: "paused")
        if !enabled { held = false; audio.restore() }
        awaitRelease = fnMonitor.isDown
        updateStatus()
    }

    @objc func suspend() {
        testingMute = false
        testGeneration += 1
        suspended = true
        held = false
        audio.restore()
        updateStatus()
    }

    @objc func resume() {
        suspended = false
        awaitRelease = fnMonitor.isDown
        updateStatus()
    }

    @objc func testMute() {
        guard !held && !suspended else { return }
        testingMute = true
        testGeneration += 1
        let generation = testGeneration
        held = true
        audio.mute()
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.testGeneration == generation else { return }
            self.audio.restore()
            self.held = false
            self.testingMute = false
            self.awaitRelease = self.fnMonitor.isDown
            self.updateStatus()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { updateStatus() }
    @objc func toggleLaunchAtLogin() {
        loginItem.setEnabled(!(loginItem.isEnabled || loginItem.needsApproval))
        if let error = loginItem.errorMessage { audio.log(error) }
        updateStatus()
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc func openInputSettings() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func showApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    @objc func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        fnMonitor.stop()
        held = false
        audio.restore()
        audio.log("Stopped; restored original sound settings.")
        updateStatus()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

let arguments = CommandLine.arguments
let dataDirectory: URL
if let index = arguments.firstIndex(of: "--state-directory"), arguments.indices.contains(index + 1) {
    dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
} else {
    dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FnMute", isDirectory: true)
}

do {
    if arguments.contains("--login-item-status") {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let login = LoginItemController()
        let status: [String: Any] = ["enabled": login.isEnabled, "needsApproval": login.needsApproval,
            "installedInApplications": LoginItemController.isInstalled, "status": login.status.rawValue]
        print(String(decoding: try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]), as: UTF8.self))
        exit(0)
    }
    if arguments.contains("--login-item-self-test") {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard LoginItemController.isInstalled else {
            throw AudioFailure(message: "Copy the test app into Applications before testing login registration.")
        }
        guard SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound else {
            throw AudioFailure(message: "Refusing to change an existing login registration during the test.")
        }
        try SMAppService.mainApp.register()
        defer { try? SMAppService.mainApp.unregister() }
        guard SMAppService.mainApp.status == .enabled else {
            throw AudioFailure(message: "Login registration needs macOS approval (status \(SMAppService.mainApp.status.rawValue)).")
        }
        try SMAppService.mainApp.unregister()
        guard SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound else {
            throw AudioFailure(message: "Login registration could not be removed after the test.")
        }
        print("PASS: native login item registration and removal.")
        exit(0)
    }
    if arguments.contains("--audio-status") {
        try printJSON(AudioHardware.snapshot())
        exit(0)
    }
    if arguments.contains("--status") {
        let path = dataDirectory.appendingPathComponent("status.json")
        print(String(decoding: try Data(contentsOf: path), as: UTF8.self))
        exit(0)
    }
    if arguments.contains("--watch-fn") {
        let monitor = PhysicalFnMonitor()
        monitor.refreshAccess()
        guard monitor.errorMessage == nil else {
            throw AudioFailure(message: monitor.errorMessage ?? "Cannot read physical Fn.")
        }
        print("Watching physical Fn for 60 seconds. Hold Fn, then release it.")
        fflush(stdout)
        var previous: Bool? = nil
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            let current = monitor.isDown
            if previous != current {
                print("\(ISO8601DateFormatter().string(from: Date())) Physical Fn \(current ? "DOWN" : "UP"), Quartz Fn \(quartzFnIsDown() ? "DOWN" : "UP")")
                fflush(stdout)
                previous = current
            }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, false)
        }
        monitor.stop()
        exit(0)
    }
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    let lock = open(dataDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw AudioFailure(message: "Could not create the app lock.") }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        print("Fn Mute is already running.")
        exit(0)
    }
    let audio = try AudioController(directory: dataDirectory)
    if arguments.contains("--restore") {
        audio.restore()
        if let error = audio.lastError { throw AudioFailure(message: error) }
        print("Original sound settings restored.")
        exit(0)
    }
    if arguments.contains("--self-test") {
        var fn = PhysicalFnState()
        fn.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: true, physical: true)
        // A dictation app's synthetic Fn-up must not release the physical key.
        fn.receive(device: 99, cookie: 296, page: 0xff, usage: 3, down: false, physical: false)
        guard fn.isDown else { throw AudioFailure(message: "Synthetic Fn release cleared the physical hold.") }
        fn.receive(device: 1, cookie: 2, page: 7, usage: 4, down: false, physical: true)
        guard fn.isDown else { throw AudioFailure(message: "A different key cleared the Fn hold.") }
        fn.receive(device: 2, cookie: 1, page: 0xff01, usage: 3, down: true, physical: true)
        fn.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: false, physical: true)
        guard fn.isDown else { throw AudioFailure(message: "A second held Fn key was lost.") }
        fn.remove(device: 2)
        guard !fn.isDown else { throw AudioFailure(message: "Disconnected Fn key remained held.") }
        fn.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: true, physical: true)
        fn.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: false, physical: true)
        guard !fn.isDown else { throw AudioFailure(message: "Physical Fn release was ignored.") }
        guard audio.saved.isEmpty else { throw AudioFailure(message: "Restore pending audio settings before testing.") }
        let before = try AudioHardware.snapshot()
        guard !before.isEmpty else { throw AudioFailure(message: "No controllable output was found.") }
        defer {
            if let devices = try? AudioHardware.devices() {
                for control in before {
                    if let device = AudioHardware.device(for: control.deviceUID, in: devices) {
                        try? AudioHardware.set(device, control, value: control.original)
                    }
                }
            }
            audio.restore()
        }
        audio.mute()
        if let error = audio.lastError { throw AudioFailure(message: error) }
        let muted = try AudioHardware.snapshot()
        guard muted.allSatisfy({ abs($0.original - $0.mutedValue) < 0.002 }) else {
            throw AudioFailure(message: "Output did not mute.")
        }
        audio.mute()
        guard audio.saved == before else { throw AudioFailure(message: "Repeated Fn hold lost the original settings.") }
        // Simulate app restart while muted: recover from the on-disk journal.
        let recovered = try AudioController(directory: dataDirectory)
        recovered.restore()
        guard try AudioHardware.snapshot() == before else {
            throw AudioFailure(message: "Recovery did not restore the original settings.")
        }
        audio.restore()
        audio.restore()
        guard try AudioHardware.snapshot() == before else {
            throw AudioFailure(message: "Repeated release changed the original settings.")
        }
        // Starting with muted audio must leave it muted after Fn is released.
        audio.mute()
        let alreadyMuted = try AudioHardware.snapshot()
        let nested = try AudioController(directory: dataDirectory.appendingPathComponent("already-muted-test"))
        nested.mute()
        nested.restore()
        guard try AudioHardware.snapshot() == alreadyMuted else {
            throw AudioFailure(message: "Originally muted audio was incorrectly unmuted.")
        }
        audio.restore()
        guard try AudioHardware.snapshot() == before else {
            throw AudioFailure(message: "Final sound settings differ from the starting settings.")
        }
        print("PASS: physical Fn latch, ignored synthetic Fn-up, multiple keyboards, disconnect recovery, mute/release, restart recovery, and already-muted output preservation.")
        exit(0)
    }
    let application = NSApplication.shared
    let delegate = AppDelegate(audio: audio)
    application.delegate = delegate
    application.run()
} catch {
    fputs("Fn Mute: \(error.localizedDescription)\n", stderr)
    exit(1)
}
