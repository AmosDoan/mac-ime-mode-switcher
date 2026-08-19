import AppKit
import Carbon
import Carbon.HIToolbox

// MARK: - Input source helpers

/// Reads a CFString property from a TIS input source.
func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

/// Reads a CFBoolean property from a TIS input source.
func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
}

struct SourceInfo {
    let source: TISInputSource
    let id: String
    let bundleID: String
    let selectable: Bool
    let enabled: Bool
    let category: String
}

/// Enumerates every installed keyboard input source (layouts + input modes).
func allInstalledSources() -> [SourceInfo] {
    guard let cfList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else { return [] }
    let list = cfList as! [TISInputSource]
    var result: [SourceInfo] = []
    for src in list {
        let id = stringProperty(src, kTISPropertyInputSourceID) ?? ""
        let bundle = stringProperty(src, kTISPropertyBundleID) ?? ""
        let category = stringProperty(src, kTISPropertyInputSourceCategory) ?? ""
        // Keep only keyboard layouts and keyboard input modes.
        guard category == (kTISCategoryKeyboardInputSource as String) else { continue }
        result.append(SourceInfo(
            source: src,
            id: id,
            bundleID: bundle,
            selectable: boolProperty(src, kTISPropertyInputSourceIsSelectCapable),
            enabled: boolProperty(src, kTISPropertyInputSourceIsEnabled),
            category: category
        ))
    }
    return result
}

// MARK: - Configuration

/// Exact input source IDs that make up each mode.
/// Edit these if you use different layouts (run scripts/list-sources.sh to see IDs).
enum Config {
    /// 한/영 모드: English + Korean 2-set. 처음 진입 시 English로 시작합니다.
    static let krEn = ["com.apple.keylayout.ABC",
                       "com.apple.inputmethod.Korean.2SetKorean"]
    static let krEnPrimary = "com.apple.keylayout.ABC"

    /// 일본어 모드: 로마자 입력(히라가나)만. 英数 전환은 IME 안에서 됩니다.
    static let jp = ["com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"]
    static let jpPrimary = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
}

enum Mode {
    case krEn
    case jp

    var title: String {
        switch self {
        case .krEn: return "한/A"
        case .jp:   return "あ"
        }
    }

    var menuLabel: String {
        switch self {
        case .krEn: return "현재: 한/영 모드"
        case .jp:   return "현재: 일본어 모드"
        }
    }
}

// MARK: - Mode switching engine

final class ModeSwitcher {
    /// Applies the given mode: enable exactly the wanted sources, select the primary,
    /// then disable every other currently-enabled source so shift+space 순환에는
    /// 딱 원하는 것만 남습니다 (Kana 일본어·아이누어 등 원치 않는 소스 제거).
    func apply(_ mode: Mode) {
        let wantedIDs: [String]
        let primaryID: String
        switch mode {
        case .krEn: wantedIDs = Config.krEn; primaryID = Config.krEnPrimary
        case .jp:   wantedIDs = Config.jp;   primaryID = Config.jpPrimary
        }

        let sources = allInstalledSources()
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Enable every wanted source first.
        for id in wantedIDs {
            if let info = byID[id], !info.enabled {
                TISEnableInputSource(info.source)
            }
        }

        // 2. Select the primary source for this mode.
        if let primary = byID[primaryID] {
            TISSelectInputSource(primary.source)
        }

        // 3. Disable every other currently-enabled selectable source.
        let wantedSet = Set(wantedIDs)
        for info in sources where info.enabled && info.selectable && !wantedSet.contains(info.id) {
            TISDisableInputSource(info.source)
        }
    }
}

// MARK: - Hotkey configuration & persistence

struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Default: ⌥⌘J (option-command-J).
    static let defaultConfig = HotKeyConfig(keyCode: UInt32(kVK_ANSI_J),
                                            carbonModifiers: UInt32(optionKey | cmdKey))

    static func load() -> HotKeyConfig {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotkey.keyCode") != nil else { return .defaultConfig }
        return HotKeyConfig(keyCode: UInt32(d.integer(forKey: "hotkey.keyCode")),
                            carbonModifiers: UInt32(d.integer(forKey: "hotkey.carbonMods")))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "hotkey.keyCode")
        d.set(Int(carbonModifiers), forKey: "hotkey.carbonMods")
    }

    /// e.g. "⌥⌘J" — a readable label for menus and the settings window.
    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

/// Translates NSEvent modifier flags into Carbon hotkey modifier masks.
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}

/// Human-readable names for a handful of virtual key codes; letters/digits fall
/// back to their typed character, everything else to "key<N>".
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

    /// Resolves the character a key produces using the current keyboard layout.
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

// MARK: - Global hotkey (Carbon, no accessibility permission needed)

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

// MARK: - Shortcut recorder button

/// A button that, while armed, captures the next modifier+key combo the user presses.
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

    func update(config: HotKeyConfig) {
        currentConfig = config
        refreshTitle()
    }

    private func refreshTitle() {
        title = recording ? "키 조합을 누르세요… (Esc 취소)" : currentConfig.display
    }

    @objc private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let mods = carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier so we don't grab bare keys.
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

// MARK: - Preferences window

final class PreferencesWindowController: NSWindowController {
    private let onChange: (HotKeyConfig) -> Void
    private var recorder: RecorderButton!

    init(config: HotKeyConfig, onChange: @escaping (HotKeyConfig) -> Void) {
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "IME Mode Switcher 설정"
        super.init(window: window)
        buildContent(config: config)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent(config: HotKeyConfig) {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString: "모드 전환 단축키")
        label.frame = NSRect(x: 20, y: 100, width: 340, height: 20)
        content.addSubview(label)

        recorder = RecorderButton(config: config)
        recorder.frame = NSRect(x: 20, y: 62, width: 260, height: 30)
        recorder.onCapture = { [weak self] cfg in
            self?.onChange(cfg)
        }
        content.addSubview(recorder)

        let reset = NSButton(title: "기본값", target: self, action: #selector(resetToDefault))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 285, y: 62, width: 75, height: 30)
        content.addSubview(reset)

        let hint = NSTextField(labelWithString: "버튼을 누른 뒤 원하는 조합(예: ⌥⌘J)을 눌러 지정합니다.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 24, width: 340, height: 20)
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
    private let switcher = ModeSwitcher()
    private var hotKey: HotKey?
    private var config = HotKeyConfig.load()
    private var mode: Mode = .krEn {
        didSet { refreshUI() }
    }
    private var modeMenuItem: NSMenuItem!
    private var hotkeyMenuItem: NSMenuItem!
    private var prefsController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        registerHotKey()

        // Establish a known state on launch: 한/영 모드.
        setMode(.krEn)
    }

    private func registerHotKey() {
        hotKey = HotKey(keyCode: config.keyCode, modifiers: config.carbonModifiers) { [weak self] in
            self?.toggleMode()
        }
        hotkeyMenuItem?.title = "단축키: \(config.display) (모드 토글)"
    }

    private func buildMenu() {
        let menu = NSMenu()
        modeMenuItem = NSMenuItem(title: mode.menuLabel, action: nil, keyEquivalent: "")
        modeMenuItem.isEnabled = false
        menu.addItem(modeMenuItem)
        menu.addItem(.separator())

        let toKrEn = NSMenuItem(title: "한/영 모드로 전환", action: #selector(switchToKrEn), keyEquivalent: "")
        toKrEn.target = self
        menu.addItem(toKrEn)

        let toJp = NSMenuItem(title: "일본어 모드로 전환", action: #selector(switchToJp), keyEquivalent: "")
        toJp.target = self
        menu.addItem(toJp)

        menu.addItem(.separator())
        hotkeyMenuItem = NSMenuItem(title: "단축키: \(config.display) (모드 토글)", action: nil, keyEquivalent: "")
        hotkeyMenuItem.isEnabled = false
        menu.addItem(hotkeyMenuItem)

        let prefs = NSMenuItem(title: "설정…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshUI()
    }

    private func refreshUI() {
        statusItem?.button?.title = mode.title
        modeMenuItem?.title = mode.menuLabel
    }

    func toggleMode() {
        setMode(mode == .krEn ? .jp : .krEn)
    }

    private func setMode(_ newMode: Mode) {
        switcher.apply(newMode)
        mode = newMode
    }

    @objc private func switchToKrEn() { setMode(.krEn) }
    @objc private func switchToJp() { setMode(.jp) }

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(config: config) { [weak self] newConfig in
                guard let self = self else { return }
                self.config = newConfig
                newConfig.save()
                self.registerHotKey() // re-registers with the new combo
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
