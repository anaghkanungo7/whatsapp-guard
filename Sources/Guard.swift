import AppKit
import Security
import CommonCrypto
import LocalAuthentication
import ServiceManagement

let guardID = "local.codex.whatsapp-guard"
let targetID = "net.whatsapp.WhatsApp"

struct PasscodeRecord: Codable {
    let salt: Data
    let digest: Data
    let rounds: UInt32
}

enum PasscodeStore {
    static func derive(_ passcode: String, salt: Data, rounds: UInt32) -> Data {
        let password = Array(passcode.utf8)
        var result = [UInt8](repeating: 0, count: 32)
        let code = password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &result, result.count)
            }
        }
        precondition(code == kCCSuccess)
        return Data(result)
    }
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: guardID, kSecAttrAccount as String: "passcode-verifier"]
    }
    static var isConfigured: Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // Access failures must not be interpreted as an absent passcode.
        return SecItemCopyMatching(q as CFDictionary, nil) != errSecItemNotFound
    }
    static func load() -> PasscodeRecord? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(PasscodeRecord.self, from: data)
    }
    static func save(_ passcode: String) throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: guardID, code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not generate a secure salt."])
        }
        let salt = Data(bytes), rounds: UInt32 = 600_000
        let record = PasscodeRecord(salt: salt, digest: derive(passcode, salt: salt, rounds: rounds), rounds: rounds)
        let data = try JSONEncoder().encode(record)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            q[kSecAttrLabel as String] = "WhatsApp Guard passcode"
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        } else if update != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
    }
    static func matches(_ passcode: String, record: PasscodeRecord) -> Bool {
        let candidate = derive(passcode, salt: record.salt, rounds: record.rounds)
        guard candidate.count == record.digest.count else { return false }
        return zip(candidate, record.digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct LockState {
    var locked = true
    var lastActivity = ProcessInfo.processInfo.systemUptime
    var timeout: TimeInterval = 300
    mutating func authenticate(now: TimeInterval) { locked = false; lastActivity = now }
    mutating func leave() { locked = true }
    mutating func tick(now: TimeInterval, idle: TimeInterval) -> Bool {
        if !locked && now - lastActivity >= timeout && idle >= timeout { locked = true; return true }
        return false
    }
}

final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class GuardDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    var state = LockState()
    var statusItem: NSStatusItem!
    var lockWindow: LockWindow!
    var passwordField = NSSecureTextField()
    var feedback = NSTextField(labelWithString: "")
    var statusLabel = NSTextField(labelWithString: "")
    var touchButton: NSButton!
    var unlockButton: NSButton!
    var timer: Timer?
    var curtains: [NSWindow] = []
    var failedAttempts = 0
    var retryAt: TimeInterval = 0
    var authenticating = false
    var authGeneration = 0
    var context: LAContext?
    var unlockingUntil: TimeInterval = 0
    var launchInFlight = false
    var isInitialSetup = false
    var changeWindow: NSWindow?
    var newPasscode = NSSecureTextField()
    var confirmPasscode = NSSecureTextField()
    var changeFeedback = NSTextField(labelWithString: "")
    var pendingAction: (() -> Void)?
    var target: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: targetID).first }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: guardID).contains(where: { $0.processIdentifier != getpid() }) {
            NSRunningApplication.runningApplications(withBundleIdentifier: guardID).first(where: { $0.processIdentifier != getpid() })?.activate(options: [])
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        state.timeout = 300
        makeMenu(); makeLockWindow()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(deactivated(_:)), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(targetAppeared(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(sleeping), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(spaceChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        lock(reason: "Started protected", show: target?.isActive == true)
        timer = Timer(timeInterval: 0.2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        if PasscodeStore.load() == nil {
            if PasscodeStore.isConfigured { showSetupError() }
            else { showChangePasscode(isSetup: true) }
        }
    }

    func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "WhatsApp Guard - locked")
        let menu = NSMenu()
        let title = NSMenuItem(title: "WhatsApp Guard • Locked", action: nil, keyEquivalent: "")
        title.tag = 1; menu.addItem(title)
        menu.addItem(NSMenuItem(title: "Locks on switch away · 5 min idle", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        addItem(menu, "Unlock WhatsApp…", #selector(openUnlock), "")
        addItem(menu, "Lock WhatsApp now", #selector(lockNow), "")
        menu.addItem(.separator())
        addItem(menu, "Change passcode…", #selector(changePasscode), "")
        addItem(menu, "Launch at login", #selector(toggleLogin), "")
        menu.items.last?.tag = 2
        addItem(menu, "About WhatsApp Guard", #selector(about), "")
        menu.addItem(.separator())
        addItem(menu, "Quit WhatsApp Guard…", #selector(quit), "")
        statusItem.menu = menu
        updateMenu()
    }
    func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    func updateMenu() {
        statusItem?.menu?.item(withTag: 1)?.title = state.locked ? "WhatsApp Guard • Locked" : "WhatsApp Guard • Unlocked"
        statusItem?.button?.image = NSImage(systemSymbolName: state.locked ? "lock.shield.fill" : "lock.open.fill", accessibilityDescription: state.locked ? "WhatsApp Guard - locked" : "WhatsApp Guard - unlocked")
        statusItem?.menu?.item(withTag: 2)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func makeLockWindow() {
        lockWindow = LockWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        lockWindow.title = "WhatsApp Guard"
        lockWindow.isReleasedWhenClosed = false; lockWindow.delegate = self
        lockWindow.level = .floating
        lockWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let root = NSView(); lockWindow.contentView = root
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 16; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: root.centerXAnchor), stack.centerYAnchor.constraint(equalTo: root.centerYAnchor), stack.widthAnchor.constraint(equalToConstant: 352)])
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "Locked")!)
        icon.contentTintColor = NSColor.systemGreen; icon.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        stack.addArrangedSubview(icon)
        let heading = NSTextField(labelWithString: "Your chats are protected")
        heading.font = .systemFont(ofSize: 23, weight: .semibold); stack.addArrangedSubview(heading)
        statusLabel.stringValue = "Unlock to return to WhatsApp."
        statusLabel.textColor = .secondaryLabelColor; statusLabel.alignment = .center; stack.addArrangedSubview(statusLabel)
        passwordField.placeholderString = "Passcode"; passwordField.font = .systemFont(ofSize: 19)
        passwordField.alignment = .center; passwordField.delegate = self
        passwordField.setAccessibilityLabel("Passcode")
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(passwordField)
        passwordField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        passwordField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        unlockButton = NSButton(title: "Unlock WhatsApp", target: self, action: #selector(unlockWithPasscode))
        unlockButton.bezelStyle = .rounded; unlockButton.controlSize = .large; unlockButton.keyEquivalent = "\r"
        stack.addArrangedSubview(unlockButton)
        touchButton = NSButton(title: "Use Touch ID", target: self, action: #selector(unlockWithTouchID))
        touchButton.bezelStyle = .rounded; stack.addArrangedSubview(touchButton)
        feedback.textColor = .systemRed; feedback.alignment = .center; feedback.font = .systemFont(ofSize: 12)
        feedback.lineBreakMode = .byWordWrapping; feedback.maximumNumberOfLines = 2
        stack.addArrangedSubview(feedback)
        let footer = NSTextField(labelWithString: "Other apps keep running while WhatsApp is locked.")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .tertiaryLabelColor; stack.addArrangedSubview(footer)
    }
    func showUnlock() {
        passwordField.stringValue = ""; feedback.stringValue = ""
        statusLabel.stringValue = "Unlock to return to WhatsApp."
        let ctx = LAContext(); var error: NSError?
        touchButton.isHidden = !ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        lockWindow.center(); lockWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        lockWindow.makeFirstResponder(passwordField)
    }
    func showCurtains() {
        guard curtains.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = NSColor.windowBackgroundColor; w.isOpaque = true
            w.level = .screenSaver; w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "WhatsApp is protected")
            label.font = .systemFont(ofSize: 24, weight: .medium); label.alignment = .center
            label.frame = NSRect(x: 0, y: screen.frame.height / 2, width: screen.frame.width, height: 40)
            w.contentView?.addSubview(label); w.orderFrontRegardless(); curtains.append(w)
        }
    }
    func removeCurtains() { curtains.forEach { $0.orderOut(nil) }; curtains.removeAll() }
    func concealTarget() {
        guard let app = target else { removeCurtains(); return }
        if !app.isHidden {
            showCurtains()
            _ = app.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                if self.target?.isHidden != false { self.removeCurtains() }
                else { self.feedback.stringValue = "WhatsApp could not be hidden. Protection remains on screen." }
            }
        } else { removeCurtains() }
    }
    func lock(reason: String, show: Bool) {
        authGeneration += 1; pendingAction = nil
        state.leave(); unlockingUntil = 0
        context?.invalidate(); context = nil; authenticating = false
        passwordField.stringValue = ""; unlockButton?.isEnabled = true
        concealTarget(); updateMenu()
        if show { showUnlock() }
        else { lockWindow?.orderOut(nil) }
    }
    @objc func activated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == targetID {
            if state.locked { concealTarget(); if !lockWindow.isVisible { showUnlock() } }
            else { unlockingUntil = 0; launchInFlight = false }
        } else if app.bundleIdentifier != guardID && !state.locked {
            // Unlocking hands activation to WhatsApp asynchronously. Its stale deactivation is ignored briefly.
            if ProcessInfo.processInfo.systemUptime >= unlockingUntil { lock(reason: "Switched away from WhatsApp", show: false) }
        }
    }
    @objc func deactivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == targetID, !state.locked,
              ProcessInfo.processInfo.systemUptime >= unlockingUntil else { return }
        lock(reason: "Switched away from WhatsApp", show: false)
    }
    @objc func targetAppeared(_ n: Notification) {
        guard state.locked, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == targetID else { return }
        concealTarget()
        if app.isActive && !lockWindow.isVisible { showUnlock() }
    }
    @objc func sleeping() { lock(reason: "Display or session became inactive", show: false) }
    @objc func spaceChanged() { if state.locked { removeCurtains(); concealTarget() } }
    @objc func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if state.locked {
            let active = target?.isActive == true
            concealTarget()
            if active && !lockWindow.isVisible { showUnlock() }
        } else {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
            if idle < 0.5 { state.lastActivity = now }
            if state.tick(now: now, idle: idle) { lock(reason: "Five minutes without activity", show: true) }
            else if now >= unlockingUntil, !launchInFlight, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != targetID {
                lock(reason: "Switched away from WhatsApp", show: false)
            }
        }
        if retryAt > now { feedback.stringValue = "Try again in \(Int(ceil(retryAt - now))) seconds." }
    }
    @objc func openUnlock() { lock(reason: "Authentication requested", show: true) }
    @objc func lockNow() { lock(reason: "Manually locked", show: false) }
    @objc func unlockWithPasscode() {
        guard !authenticating else { return }
        guard ProcessInfo.processInfo.systemUptime >= retryAt else { return }
        guard let record = PasscodeStore.load() else { showSetupError(); return }
        let passcode = passwordField.stringValue; passwordField.stringValue = ""
        let generation = authGeneration
        authenticating = true; unlockButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let success = PasscodeStore.matches(passcode, record: record)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.authGeneration == generation else { return }
                self.authenticating = false; self.unlockButton.isEnabled = true
                if success { self.authenticated() }
                else {
                    self.failedAttempts += 1
                    if self.failedAttempts >= 5 { self.retryAt = ProcessInfo.processInfo.systemUptime + min(60, Double(self.failedAttempts - 4) * 10) }
                    self.feedback.stringValue = "Incorrect passcode. Your chats remain protected."
                    self.lockWindow.makeFirstResponder(self.passwordField)
                }
            }
        }
    }
    @objc func unlockWithTouchID() {
        guard !authenticating else { return }
        let ctx = LAContext(); context = ctx; authenticating = true
        ctx.localizedFallbackTitle = ""; ctx.touchIDAuthenticationAllowableReuseDuration = 0
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your WhatsApp chats") { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self, self.context === ctx else { return }
                self.authenticating = false; self.context = nil
                if success { self.authenticated() }
                else { self.feedback.stringValue = "Touch ID was not completed. Enter your passcode." }
            }
        }
    }
    func authenticated() {
        failedAttempts = 0; retryAt = 0; passwordField.stringValue = ""
        lockWindow.orderOut(nil)
        if let action = pendingAction { pendingAction = nil; action(); return }
        state.authenticate(now: ProcessInfo.processInfo.systemUptime)
        unlockingUntil = ProcessInfo.processInfo.systemUptime + 2
        removeCurtains(); updateMenu()
        if let app = target { app.unhide(); app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
        else {
            launchInFlight = true
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/WhatsApp.app"), configuration: config) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }; self.launchInFlight = false
                    self.unlockingUntil = ProcessInfo.processInfo.systemUptime + 1
                    if let error { self.lock(reason: "WhatsApp could not open", show: true); self.feedback.stringValue = error.localizedDescription }
                }
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == lockWindow {
            authGeneration += 1
            context?.invalidate(); context = nil; authenticating = false; pendingAction = nil
            passwordField.stringValue = ""; lockWindow.orderOut(nil); concealTarget(); return false
        }
        return true
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            updateMenu()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { alert("Launch at login", error.localizedDescription) }
    }
    @objc func changePasscode() {
        lock(reason: "Change passcode requires authentication", show: true)
        statusLabel.stringValue = "Authenticate to change your passcode."
        pendingAction = { [weak self] in self?.showChangePasscode() }
    }
    func showChangePasscode(isSetup: Bool = false) {
        isInitialSetup = isSetup
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = isSetup ? "Set up WhatsApp Guard" : "Change passcode"; w.isReleasedWhenClosed = false
        changeWindow = w
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor), stack.centerYAnchor.constraint(equalTo: w.contentView!.centerYAnchor), stack.widthAnchor.constraint(equalToConstant: 320)])
        stack.addArrangedSubview(NSTextField(labelWithString: "Choose a passcode with at least 6 characters."))
        newPasscode = NSSecureTextField(); newPasscode.placeholderString = "New passcode"
        confirmPasscode = NSSecureTextField(); confirmPasscode.placeholderString = "Confirm passcode"
        for field in [newPasscode, confirmPasscode] { stack.addArrangedSubview(field); field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        let button = NSButton(title: isSetup ? "Set passcode" : "Save passcode", target: self, action: #selector(savePasscode)); button.bezelStyle = .rounded; stack.addArrangedSubview(button)
        changeFeedback.stringValue = ""; changeFeedback.textColor = .systemRed; stack.addArrangedSubview(changeFeedback)
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); w.makeFirstResponder(newPasscode)
    }
    @objc func savePasscode() {
        guard newPasscode.stringValue.count >= 6 else { changeFeedback.stringValue = "Use at least 6 characters."; return }
        guard newPasscode.stringValue == confirmPasscode.stringValue else { changeFeedback.stringValue = "The passcodes do not match."; return }
        do {
            try PasscodeStore.save(newPasscode.stringValue)
            newPasscode.stringValue = ""; confirmPasscode.stringValue = ""; changeWindow?.close(); changeWindow = nil
            let wasSetup = isInitialSetup; isInitialSetup = false
            showUnlock(); statusLabel.stringValue = wasSetup ? "Passcode saved. Unlock to return to WhatsApp." : "Passcode updated. Unlock to return to WhatsApp."
        } catch { changeFeedback.stringValue = "Could not save to Keychain." }
    }
    @objc func quit() {
        lock(reason: "Quit requested", show: true)
        statusLabel.stringValue = "Authenticate to quit WhatsApp Guard."
        pendingAction = { NSApp.terminate(nil) }
    }
    @objc func about() {
        alert("WhatsApp Guard", "Version 1.0.0\n\nProtects the native WhatsApp app while your other apps keep running. Locks when you switch away, after five minutes without activity, and when the display sleeps.\n\nThis is a local privacy guard. It does not encrypt WhatsApp or prevent a user from force-quitting the guard. Call and message notifications are controlled separately in WhatsApp and macOS.")
    }
    func alert(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
    func showSetupError() {
        showUnlock(); feedback.stringValue = "Passcode is not available. Check access in Keychain Access, then restart the guard."
        unlockButton.isEnabled = false; touchButton.isHidden = true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openUnlock(); return true }
    func applicationWillTerminate(_ notification: Notification) { target?.hide(); removeCurtains(); timer?.invalidate() }
}

func runTests() {
    func check(_ value: @autoclosure () -> Bool, _ name: String) { guard value() else { print("FAIL: \(name)"); exit(1) }; print("PASS: \(name)") }
    let salt = Data(repeating: 7, count: 16), rounds: UInt32 = 1000
    let digest = PasscodeStore.derive("test-passcode", salt: salt, rounds: rounds)
    let record = PasscodeRecord(salt: salt, digest: digest, rounds: rounds)
    check(PasscodeStore.matches("test-passcode", record: record), "Correct passcode accepted")
    check(!PasscodeStore.matches("wrong-passcode", record: record), "Incorrect passcode rejected")
    check(PasscodeStore.derive("test-passcode", salt: Data(repeating: 8, count: 16), rounds: rounds) != digest, "Unique salts produce different verifiers")
    let vector = PasscodeStore.derive("password", salt: Data("salt".utf8), rounds: 1).map { String(format: "%02x", $0) }.joined()
    check(vector == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "PBKDF2-SHA256 known-answer vector")
    var state = LockState()
    check(state.locked, "Starts locked")
    state.authenticate(now: 100)
    check(!state.tick(now: 399, idle: 299) && !state.locked, "No premature inactivity lock")
    check(state.tick(now: 400, idle: 300) && state.locked, "Locks at exactly five minutes")
    check(!state.tick(now: 401, idle: 0) && state.locked, "Mouse activity cannot unlock")
    state.authenticate(now: 500); state.leave()
    check(state.locked, "Switching away relocks")
}

let arguments = CommandLine.arguments
if arguments.contains("--self-test") { runTests(); exit(0) }
if arguments.contains("--configure-passcode-stdin") {
    guard !PasscodeStore.isConfigured else { fputs("A passcode already exists. Change it from the authenticated app menu.\n", stderr); exit(1) }
    guard let value = readLine(), value.count >= 6 else { fputs("Passcode must contain at least 6 characters.\n", stderr); exit(1) }
    do { try PasscodeStore.save(value); print("Passcode configured in Keychain."); exit(0) }
    catch { fputs("Keychain setup failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = GuardDelegate()
app.delegate = delegate
app.run()
