# IME Mode Switcher

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

## 권한

shift+space 를 가로채려면 **손쉬운 사용(접근성)** 권한이 필요합니다.
처음 실행하면 안내가 뜹니다. `시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용`
에서 IMEModeSwitcher 를 켠 뒤 앱을 다시 실행하세요.

> 참고: 앱을 다시 빌드하면(ad-hoc 서명) 권한 목록에서 한 번 껐다 켜야 할 수 있습니다.

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

`시스템 설정 > 일반 > 로그인 항목` 에 `build/IMEModeSwitcher.app` 를 추가합니다.
