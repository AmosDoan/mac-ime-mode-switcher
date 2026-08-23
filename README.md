# IME Mode Switcher

A tiny macOS menu-bar app that makes switching between Korean, English, and
Japanese input sources fast and predictable. Keep using **shift+space** for
Korean ↔ English, without ever overshooting into Japanese.

## English

macOS's "select next input source" cycle (shift+space) walks **every** enabled
source, so pressing it quickly can overshoot into input sources you didn't want
(Japanese, Ainu, …). And on recent macOS the input-source *disable* API
(`TISDisableInputSource`) no longer works, so you can't fix it by trimming the
cycle.

Instead, this app **intercepts the shift+space keystroke itself**, swallows the
system cycle, and switches Korean ↔ English directly. It never lands on Japanese.

- **shift+space** → Korean ↔ English (intercepted, selected directly)
- **⌥⌘J** → 日本語 (Romaji), a dedicated key that can't overshoot
- The menu-bar shows the current language (`한` / `A` / `あ`); you can also pick one from the menu.
- The Japanese shortcut is configurable in the menu-bar `설정…` (Settings) window.

**Requirements:** enable *Japanese – Romaji* in `System Settings > Keyboard >
Input Sources` (the app only *selects* sources, never enables/disables them), and
grant **Accessibility** permission so the app can intercept shift+space. Once
granted, interception starts immediately (no relaunch needed).

**Build:** run `./scripts/create-signing-identity.sh` once (a stable self-signed
identity so the Accessibility grant survives rebuilds), then `./scripts/build.sh`
and `open build/IMEModeSwitcher.app`. Toggle **로그인 시 자동 실행** (Launch at
login) from the menu so the app is always running.

The rest of this README is in Korean.

---

한/영/일 입력 소스를 빠르고 정확하게 전환하는 macOS 메뉴바 앱입니다.
shift+space 로 한/영을 쓰던 습관은 그대로 두고, 일본어로 새는(오버슛) 문제만 없앱니다.

## 왜?

macOS 의 shift+space "다음 입력 소스" 순환은 활성화된 모든 소스를 돕니다. 그래서
빠르게 여러 번 누르면 원치 않는 일본어·아이누어까지 튀어나옵니다. 게다가 macOS 의
입력 소스 "끄기" API(`TISDisableInputSource`)는 최신 버전에서 동작하지 않아, 순환에서
소스를 빼는 방식으로는 해결되지 않습니다.

이 앱은 대신 **shift+space 키 입력 자체를 가로채서**, 시스템 순환을 삼켜버리고
직접 한 ↔ 영만 전환합니다. 일본어·아이누어로는 절대 넘어가지 않습니다.

- **shift+space** → 한 ↔ 영 (앱이 가로채 직접 선택)
- **⌥⌘J** → 日本語 (로마자 입력)
- 메뉴바에 현재 언어가 `한` / `A` / `あ` 로 표시됩니다. 메뉴에서 직접 선택도 됩니다.
- 일본어 단축키는 메뉴바 `설정…` 에서 원하는 조합으로 바꿀 수 있습니다.

일본어 키(`⌥⌘J`)로 전환하려면 **일본어 - 로마자** 입력 소스가 시스템에 켜져 있어야
합니다 (`시스템 설정 > 키보드 > 입력 소스`). 이 앱은 소스를 켜고/끄지 않고 선택만
합니다 (최근 macOS 에서 입력 소스 끄기 API 가 동작하지 않기 때문입니다).

## 권한

shift+space 를 가로채려면 **손쉬운 사용(접근성)** 권한이 필요합니다.
처음 실행하면 안내가 뜹니다. `시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용`
에서 IMEModeSwitcher 를 켜면, 앱이 **재실행 없이 즉시** 가로채기를 시작합니다
(메뉴에 "가로채기: 켜짐 ✓" 으로 표시됩니다).

> 재빌드해도 권한이 유지되도록 안정적인 자체 서명으로 서명합니다. 최초 1회만
> `./scripts/create-signing-identity.sh` 를 실행해 서명 인증서를 만들어 두세요.
> (없으면 build.sh 는 ad-hoc 서명으로 대체하며, 이 경우 재빌드마다 권한을 다시
> 켜야 합니다.)

## 빌드

```bash
./scripts/build.sh
open build/IMEModeSwitcher.app
```

## 설정 바꾸기

입력 소스 ID 는 아래로 확인합니다.

```bash
./scripts/list-sources.sh
```

소스 ID 는 `Sources/main.swift` 의 `Config`, 일본어 단축키 기본값은
`HotKeyConfig.defaultConfig` 에 있습니다.

## 로그인 시 자동 실행

메뉴바 아이콘 → **로그인 시 자동 실행** 을 켜면 됩니다 (앱 내에서 바로 등록/해제).
앱이 떠 있어야 shift+space 가로채기가 동작하므로 켜두길 권합니다.
