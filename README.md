# IME Mode Switcher

한/영/일 입력 소스를 두 개의 "모드"로 나눠, 잘 안 쓰는 단축키 하나로 토글하는 macOS 메뉴바 앱입니다.

## 왜?

macOS에서 shift+space 입력 소스 순환에 여러 소스가 물려 있으면, 빠르게 여러 번
누를 때 원치 않는 소스(예: 카나 일본어, 아이누어)가 튀어나옵니다. 이 앱은
현재 모드에 필요한 소스만 남기고 나머지는 비활성화해서, shift+space 순환을
항상 깔끔하게 유지합니다.

- **한/영 모드**: `ABC`(영어) + `한국어 2벌식`만 활성화. shift+space는 이 둘만 순환합니다.
- **일본어 모드**: `Kotoeri 로마자 입력(히라가나)`만 활성화. 英数 전환은 IME 안에서 합니다.

두 모드는 **⌥⌘J** 로 토글합니다 (메뉴바 아이콘 클릭으로도 전환 가능).
단축키는 메뉴바 `설정…` 에서 원하는 조합을 직접 눌러 바꿀 수 있습니다.
메뉴바에는 현재 모드가 `한/A` 또는 `あ` 로 표시됩니다.

> 팁: macOS `시스템 설정 > 키보드 > 입력 소스` 는 한국어·ABC 둘만 남겨두는 게
> 좋습니다. 일본어는 이 앱이 일본어 모드일 때 자동으로 켜고, 한/영 모드에서
> 다시 끕니다. Kotoeri 는 목록에서 빼도 macOS 에 계속 설치되어 있습니다.

## 빌드

```bash
./scripts/build.sh
open build/IMEModeSwitcher.app
```

접근성 권한이 필요 없습니다 (전역 단축키는 Carbon `RegisterEventHotKey` 사용).

## 설정 바꾸기

`Sources/main.swift` 상단 `Config` 에서 모드별 입력 소스 ID를 수정합니다.
설치된 소스 ID 목록은 아래로 확인합니다.

```bash
./scripts/list-sources.sh
```

단축키는 앱 메뉴바 `설정…` 에서 바꾸는 게 가장 쉽고, 기본값은 `HotKeyConfig.defaultConfig` 에 있습니다.

## 로그인 시 자동 실행

`시스템 설정 > 일반 > 로그인 항목` 에 `build/IMEModeSwitcher.app` 를 추가합니다.
