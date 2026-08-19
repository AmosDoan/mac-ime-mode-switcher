import AppKit
import Carbon
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Configuration

/// Input source IDs. Run scripts/list-sources.sh to find yours.
enum Config {
    static let english  = "com.apple.keylayout.ABC"
    static let korean   = "com.apple.inputmethod.Korean.2SetKorean"
    static let japanese = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"

    /// Any source whose ID starts with this is treated as Korean.
    static let koreanPrefix   = "com.apple.inputmethod.Korean"
    static let japanesePrefix = "com.apple.inputmethod.Kotoeri"
}

// MARK: - Input source helpers

func sourceID(_ source: TISInputSource) -> String {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

/// The ID of the currently active keyboard input source.
func currentSourceID() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
    return sourceID(src)
}

func findSource(_ id: String) -> TISInputSource? {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
    return list.first { sourceID($0) == id }
}

/// Selects a source by ID. The source must already be enabled in System Settings —
/// programmatic enable/disable is unreliable on recent macOS, so we never touch it.
/// Returns the OSStatus (0 == success; -50 usually means the source isn't enabled).
@discardableResult
func selectSource(_ id: String) -> OSStatus {
    guard let src = findSource(id) else { return OSStatus(-50) }
    return TISSelectInputSource(src)
}

enum InputLang {
    case english, korean, japanese, other

    static func of(_ id: String) -> InputLang {
        if id == Config.english { return .english }
        if id.hasPrefix(Config.koreanPrefix) { return .korean }
        if id.hasPrefix(Config.japanesePrefix) { return .japanese }
        return .other
    }

    var glyph: String {
        switch self {
        case .english:  return "A"
        case .korean:   return "한"
        case .japanese: return "あ"
        case .other:    return "•"
        }
    }
}

// MARK: - Hotkey configuration & persistence

struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Default: ⌥⌘J (option-command-J) for Japanese.
    static let defaultConfig = HotKeyConfig(keyCode: UInt32(kVK_ANSI_J),
                                            carbonModifiers: UInt32(optionKey | cmdKey))

    static func load() -> HotKeyConfig {
        let d = UserDefaults.standard
        guard d.object(forKey: "jpHotkey.keyCode") != nil else { return .defaultConfig }
        return HotKeyConfig(keyCode: UInt32(d.integer(forKey: "jpHotkey.keyCode")),
                            carbonModifiers: UInt32(d.integer(forKey: "jpHotkey.carbonMods")))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "jpHotkey.keyCode")
        d.set(Int(carbonModifiers), forKey: "jpHotkey.carbonMods")
    }

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}

enum KeyNames {
    private static let special: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Escape): "Esc",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// ANSI virtual keycodes → characters (layout-independent, for display only).
    private static let ansi: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",
        13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
        24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",
        35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",
        47:".",50:"`",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let s = special[keyCode] { return s }
        if let s = ansi[keyCode] { return s }
        if let ch = character(for: keyCode) { return ch.uppercased() }
        return "key\(keyCode)"
    }

    private static func character(for keyCode: UInt32) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let result = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - Global key tap

/// CGEventFlags for the four modifiers described by a HotKeyConfig.
func cgFlags(from carbon: UInt32) -> CGEventFlags {
    var f: CGEventFlags = []
    if carbon & UInt32(cmdKey)     != 0 { f.insert(.maskCommand) }
    if carbon & UInt32(optionKey)  != 0 { f.insert(.maskAlternate) }
    if carbon & UInt32(controlKey) != 0 { f.insert(.maskControl) }
    if carbon & UInt32(shiftKey)   != 0 { f.insert(.maskShift) }
    return f
}

/// Intercepts key input globally: shift+space swaps 한 ↔ 영, and the configured
/// Japanese combo selects 日本語. Both are *swallowed*, so the system's input-source
/// cycle never overshoots and other apps (Notion 등) never see the Japanese combo.
final class KeyTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onShiftSpace: () -> Void
    private let onJapanese: () -> Void
    private let jpConfig: () -> HotKeyConfig

    private static let modMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    init?(jpConfig: @escaping () -> HotKeyConfig,
          onShiftSpace: @escaping () -> Void,
          onJapanese: @escaping () -> Void) {
        self.jpConfig = jpConfig
        self.onShiftSpace = onShiftSpace
        self.onJapanese = onJapanese
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return me.handle(type: type, event: event)
            }, userInfo: selfPtr)
        else { return nil }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is slow or gets interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection(Self.modMask)

        // shift+space (and nothing else) → 한 ↔ 영
        if keyCode == Int64(kVK_Space) && mods == .maskShift {
            DispatchQueue.main.async { self.onShiftSpace() }
            return nil
        }

        // configured Japanese combo → 日本語 (swallowed, so Notion never sees it)
        let jp = jpConfig()
        if keyCode == Int64(jp.keyCode) && mods == cgFlags(from: jp.carbonModifiers) {
            DispatchQueue.main.async { self.onJapanese() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    deinit {
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
    }
}

// MARK: - Shortcut recorder + Preferences (for the Japanese key)

final class RecorderButton: NSButton {
    var onCapture: ((HotKeyConfig) -> Void)?
    private var recording = false
    private var monitor: Any?
    private var currentConfig: HotKeyConfig

    init(config: HotKeyConfig) {
        self.currentConfig = config
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(config: HotKeyConfig) { currentConfig = config; refreshTitle() }

    private func refreshTitle() {
        title = recording ? "키 조합을 누르세요… (Esc 취소)" : currentConfig.display
    }

    @objc private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let mods = carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return nil }
            let config = HotKeyConfig(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            self.currentConfig = config
            self.stop()
            self.onCapture?(config)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        refreshTitle()
    }
}

final class PreferencesWindowController: NSWindowController {
    private let onChange: (HotKeyConfig) -> Void
    private var recorder: RecorderButton!

    init(config: HotKeyConfig, onChange: @escaping (HotKeyConfig) -> Void) {
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "IME Mode Switcher 설정"
        super.init(window: window)
        buildContent(config: config)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent(config: HotKeyConfig) {
        guard let content = window?.contentView else { return }

        let info = NSTextField(labelWithString: "shift+space = 한 ↔ 영 (고정)")
        info.frame = NSRect(x: 20, y: 122, width: 360, height: 20)
        content.addSubview(info)

        let label = NSTextField(labelWithString: "일본어 전환 단축키")
        label.frame = NSRect(x: 20, y: 92, width: 360, height: 20)
        content.addSubview(label)

        recorder = RecorderButton(config: config)
        recorder.frame = NSRect(x: 20, y: 54, width: 280, height: 30)
        recorder.onCapture = { [weak self] cfg in self?.onChange(cfg) }
        content.addSubview(recorder)

        let reset = NSButton(title: "기본값", target: self, action: #selector(resetToDefault))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 305, y: 54, width: 75, height: 30)
        content.addSubview(reset)

        let hint = NSTextField(labelWithString: "버튼을 누른 뒤 원하는 조합(예: ⌥⌘J)을 눌러 지정합니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 20, width: 360, height: 20)
        content.addSubview(hint)
    }

    @objc private func resetToDefault() {
        recorder.update(config: .defaultConfig)
        onChange(.defaultConfig)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var tap: KeyTap?
    private var jpConfig = HotKeyConfig.load()
    private var jpHotkeyMenuItem: NSMenuItem!
    private var tapStatusMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!
    private var prefsController: PreferencesWindowController?

    private var permissionTimer: Timer?
    private var didPrompt = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        setupTap()
        observeInputChanges()
        refreshGlyph()

        // If permission isn't granted yet, keep trying so the user never has to
        // relaunch: the tap activates the moment they flip the switch in Settings.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.tap == nil else { return }
            if AXIsProcessTrusted() { self.setupTap() }
        }
    }

    // MARK: key tap (needs Accessibility permission)

    private func setupTap() {
        guard tap == nil else { return }
        tap = KeyTap(
            jpConfig: { [weak self] in self?.jpConfig ?? .defaultConfig },
            onShiftSpace: { [weak self] in self?.toggleKoreanEnglish() },
            onJapanese: { [weak self] in self?.selectJapanese() })
        if tap != nil {
            permissionTimer?.invalidate(); permissionTimer = nil
        } else if !didPrompt {
            didPrompt = true
            promptForAccessibility()
        }
        updateTapStatusMenu()
    }

    private func promptForAccessibility() {
        // Triggers the system prompt and points the user to the right settings pane.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        let alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한이 필요합니다"
        alert.informativeText = "shift+space 를 가로채 한/영을 전환하려면 접근성 권한이 필요합니다.\n"
            + "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에서 IMEModeSwitcher 를 켠 뒤 앱을 다시 실행해 주세요."
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "나중에")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: switching

    private func toggleKoreanEnglish() {
        let cur = InputLang.of(currentSourceID())
        selectSource(cur == .korean ? Config.english : Config.korean)
    }

    private var warnedJapaneseDisabled = false
    private func selectJapanese() {
        if selectSource(Config.japanese) == -50 && !warnedJapaneseDisabled {
            warnedJapaneseDisabled = true
            let alert = NSAlert()
            alert.messageText = "일본어 입력 소스를 켜야 합니다"
            alert.informativeText = "시스템 설정 > 키보드 > 입력 소스 에서 "
                + "‘일본어 - 로마자’를 추가해 주세요. 추가하면 ⌥⌘J 로 바로 전환됩니다."
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    @objc private func menuEnglish()  { selectSource(Config.english) }
    @objc private func menuKorean()   { selectSource(Config.korean) }
    @objc private func menuJapanese() { selectJapanese() }

    // MARK: menu / indicator

    private func buildMenu() {
        let menu = NSMenu()

        tapStatusMenuItem = NSMenuItem(title: "가로채기: 확인 중…", action: nil, keyEquivalent: "")
        tapStatusMenuItem.isEnabled = false
        menu.addItem(tapStatusMenuItem)

        let ss = NSMenuItem(title: "shift+space: 한 ↔ 영", action: nil, keyEquivalent: "")
        ss.isEnabled = false
        menu.addItem(ss)

        jpHotkeyMenuItem = NSMenuItem(title: "일본어 단축키: \(jpConfig.display)", action: nil, keyEquivalent: "")
        jpHotkeyMenuItem.isEnabled = false
        menu.addItem(jpHotkeyMenuItem)

        menu.addItem(.separator())
        for (title, sel) in [("English (ABC)", #selector(menuEnglish)),
                             ("한국어", #selector(menuKorean)),
                             ("日本語", #selector(menuJapanese))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        loginItemMenuItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)

        let prefs = NSMenuItem(title: "설정…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
        refreshLoginItemState()
    }

    // Refresh dynamic states right before the menu is shown.
    func menuWillOpen(_ menu: NSMenu) {
        updateTapStatusMenu()
        refreshLoginItemState()
        refreshGlyph()
    }

    private func observeInputChanges() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshGlyph),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
    }

    private func updateTapStatusMenu() {
        tapStatusMenuItem?.title = tap != nil ? "가로채기: 켜짐 ✓" : "가로채기: 꺼짐 (권한 필요)"
    }

    private func refreshLoginItemState() {
        loginItemMenuItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목 설정에 실패했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLoginItemState()
    }

    @objc private func refreshGlyph() {
        DispatchQueue.main.async {
            self.statusItem?.button?.title = InputLang.of(currentSourceID()).glyph
        }
    }

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(config: jpConfig) { [weak self] newConfig in
                guard let self = self else { return }
                self.jpConfig = newConfig
                newConfig.save()
                // The tap reads jpConfig live, so no re-registration is needed.
                self.jpHotkeyMenuItem?.title = "일본어 단축키: \(newConfig.display)"
            }
        }
        prefsController?.show()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no dock icon
app.run()
