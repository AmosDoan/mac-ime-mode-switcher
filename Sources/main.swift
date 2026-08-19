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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let switcher = ModeSwitcher()
    private var hotKey: HotKey?
    private var mode: Mode = .krEn {
        didSet { refreshUI() }
    }
    private var modeMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        // Default hotkey: ⌃⌥⌘J  (control-option-command-J)
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_J),
                        modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.toggleMode()
        }

        // Establish a known state on launch: 한/영 모드.
        setMode(.krEn)
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
        let hint = NSMenuItem(title: "단축키: ⌃⌥⌘J (모드 토글)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no dock icon
app.run()
