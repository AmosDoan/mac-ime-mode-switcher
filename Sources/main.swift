import AppKit
import Carbon
import Carbon.HIToolbox

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

/// Selects a source by ID, enabling it first if macOS reports it disabled.
/// (Enable works reliably; disable does not, so we never rely on disabling.)
func selectSource(_ id: String) {
    guard var src = findSource(id) else { return }
    let enabledPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsEnabled)
    let enabled = enabledPtr.map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    if !enabled {
        TISEnableInputSource(src)
        if let refreshed = findSource(id) { src = refreshed }
    }
    TISSelectInputSource(src)
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

    static func name(for keyCode: UInt32) -> String {
        if let s = special[keyCode] { return s }
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

// MARK: - Global hotkey (Carbon) for the Japanese key

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        install(keyCode: keyCode, modifiers: modifiers)
    }

    private func install(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onFire() }
            return noErr
        }, 1, &spec, selfPtr, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x494D4553) /* 'IMES' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref = ref { UnregisterEventHotKey(ref) }
        if let handler = handler { RemoveEventHandler(handler) }
    }
}

// MARK: - shift+space event tap

/// Intercepts shift+space globally and swaps 한 ↔ 영 ourselves, swallowing the
/// system's "select next input source" so it can never overshoot into 日本語/Ainu.
final class ShiftSpaceTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onShiftSpace: () -> Void

    init?(onShiftSpace: @escaping () -> Void) {
        self.onShiftSpace = onShiftSpace
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<ShiftSpaceTap>.fromOpaque(userInfo).takeUnretainedValue()
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
        let flags = event.flags
        let shift = flags.contains(.maskShift)
        let otherMods = flags.contains(.maskCommand) || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)

        if keyCode == Int64(kVK_Space) && shift && !otherMods {
            DispatchQueue.main.async { self.onShiftSpace() }
            return nil // swallow: the system never runs its own switch
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var jpHotKey: HotKey?
    private var tap: ShiftSpaceTap?
    private var jpConfig = HotKeyConfig.load()
    private var jpHotkeyMenuItem: NSMenuItem!
    private var prefsController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        registerJapaneseHotKey()
        setupTap()
        observeInputChanges()
        refreshGlyph()
    }

    // MARK: shift+space tap (needs Accessibility permission)

    private func setupTap() {
        tap = ShiftSpaceTap { [weak self] in self?.toggleKoreanEnglish() }
        if tap == nil { promptForAccessibility() }
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

    private func selectJapanese() { selectSource(Config.japanese) }
    @objc private func menuEnglish()  { selectSource(Config.english) }
    @objc private func menuKorean()   { selectSource(Config.korean) }
    @objc private func menuJapanese() { selectJapanese() }

    // MARK: hotkey

    private func registerJapaneseHotKey() {
        jpHotKey = HotKey(keyCode: jpConfig.keyCode, modifiers: jpConfig.carbonModifiers) { [weak self] in
            self?.selectJapanese()
        }
        jpHotkeyMenuItem?.title = "일본어 단축키: \(jpConfig.display)"
    }

    // MARK: menu / indicator

    private func buildMenu() {
        let menu = NSMenu()

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
        let prefs = NSMenuItem(title: "설정…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func observeInputChanges() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshGlyph),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
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
                self.registerJapaneseHotKey()
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
