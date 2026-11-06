# live-trans 구현 계획

M시리즈 맥에서 마이크 음성을 온디바이스로 전사하고, 전사문을 30초 이상 묶어 사용자가 고른 언어로 번역해 텍스트로 보여 주는 네이티브 macOS 앱.

## 확정된 결정

| 항목 | 결정 |
|---|---|
| 음성 입력 | 마이크만 (`AVAudioEngine` input tap) |
| 전사 | `Speech` 프레임워크 `SpeechAnalyzer` + `SpeechTranscriber` (온디바이스) |
| 통역 엔진 | `Translation` 프레임워크 `TranslationSession` (온디바이스) |
| 원문 언어 | 시작 전 사용자가 선택 (자동 감지 없음) |
| 출력 | 메인 창 한 곳에 원문(실시간)과 번역(30초 단위)을 시간순으로 누적 |
| UI | SwiftUI, 단일 창 |
| 배포 타깃 | macOS 27 (개발 기기 macOS 27.0.1, Xcode 27.2, Swift 6.4.2) |
| 프로젝트 생성 | XcodeGen `project.yml` → `xcodebuild`로 CLI 빌드 |

배포 타깃을 macOS 27로 잡은 이유: macOS 27 SDK의 `AnalyzerInputConverter`가 마이크 버퍼를 분석기 포맷의 `AnalyzerInput`으로 바로 바꿔 줘서, `AVAudioConverter`를 직접 다루는 코드가 빠진다. macOS 26 지원이 필요해지면 그때 `AVAudioConverter` 경로를 넣는다.

## 30초 묶음 규칙

- 묶음 기준은 **오디오 시간**이다. 벽시계나 글자 수는 쓰지 않는다.
- `SpeechTranscriber`의 **확정(final) 결과**만 묶음 버퍼에 쌓는다. 각 결과의 `range`(`CMTimeRange`)로 오디오 위치를 안다.
- 버퍼의 첫 결과 시작 시각부터 마지막 결과 끝 시각까지가 **30초 이상**이 되면 그 시점에 버퍼를 통째로 번역에 넘기고 비운다. 확정 결과는 문장·휴지 단위로 나오므로 문장 중간에서 잘리지 않는다.
- **중지(Stop)** 하면 남은 버퍼를 길이와 상관없이 번역한다.
- 휘발(volatile) 결과는 화면의 "전사 중" 줄에만 보여 주고 묶음에는 넣지 않는다.
- 그래서 번역은 말한 시점보다 최소 30초 늦게 나온다. 요구사항이 정한 동작이다.

## 구조

```
LiveTransApp (SwiftUI App)
└─ ContentView ─ 언어 선택 2개 · 시작/중지 · 원문/번역 목록
     └─ SessionModel (@Observable, @MainActor)
          ├─ Transcriber   AVAudioEngine → AnalyzerInputConverter → SpeechAnalyzer
          │                 → results(AsyncSequence) → 휘발/확정 콜백
          ├─ 묶음 버퍼     확정 결과 누적, 30초 규칙으로 방출
          └─ Translator    TranslationSession(installedSource:target:).translate(_:)
```

파일은 다섯 개 안팎으로 시작한다: `LiveTransApp.swift`, `ContentView.swift`, `SessionModel.swift`, `Transcriber.swift`, `Translator.swift`. 묶음 버퍼는 `SessionModel` 안의 배열과 시각 두 개로 충분하므로 별도 타입을 만들지 않는다.

## 구현 단계

각 단계는 **`xcodebuild build` 성공 + 개발 맥에서 실행해 해당 동작을 눈으로 확인**하면 끝난다. 단위 테스트는 쓰지 않는다. 재현된 결함이 생기면 그 결함을 고정하는 테스트만 그때 추가한다.

### 1단계 — 프로젝트 골격

- `project.yml` (macOS App, SwiftUI, 배포 타깃 27.0, 번들 ID `kr.manuel71.LiveTrans` 가정)
- `Info.plist`: `NSMicrophoneUsageDescription`
- 엔타이틀먼트: App Sandbox + `com.apple.security.device.audio-input`
- `ContentView`: 원문 언어·번역 언어 선택(Picker), 시작/중지 버튼, 비어 있는 스크롤 텍스트 영역
- 원문 언어 목록은 `SpeechTranscriber.supportedLocales`, 번역 언어 목록은 `LanguageAvailability().supportedLanguages`에서 가져온다
- `.gitignore` (`*.xcodeproj` 생성물, `build/`, `DerivedData`)

완료 확인: 앱이 뜨고 두 목록이 채워진다.

### 2단계 — 실시간 전사

- 시작 시 마이크 권한 요청 → `SpeechTranscriber(locale:transcriptionOptions:reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])`
- `AssetInventory.assetInstallationRequest(supporting:)`가 요청을 돌려주면 `downloadAndInstall()`로 음성 모델을 받는다 (진행 중에는 버튼 비활성 + 문구)
- `AnalyzerInputConverter.converter(compatibleWith:)`로 마이크 탭 버퍼를 변환해 `AsyncStream<AnalyzerInput>`에 넣고 `SpeechAnalyzer.start(inputSequence:)`
- `transcriber.results`를 돌며 휘발 결과는 "전사 중" 줄을 갱신, 확정 결과는 원문 목록에 추가
- 중지 시 입력 스트림 종료 → `finalizeAndFinishThroughEndOfInput()` → 오디오 엔진 정지
- `NSSpeechRecognitionUsageDescription`이 필요한지는 이 단계에서 실제 실행으로 확인하고, 권한 오류가 날 때만 넣는다

완료 확인: 말하면 원문이 실시간으로 나오고, 중지하면 마지막 문장까지 확정된다.

### 3단계 — 30초 묶음 번역

- 위 "30초 묶음 규칙"대로 확정 결과를 묶어 방출
- 시작 시 `LanguageAvailability().status(from:to:)`로 언어쌍 상태 확인
  - `.installed` → `TranslationSession(installedSource:target:)` 생성
  - `.supported`(미설치) → 언어팩 설치가 필요하다고 표시 (설치는 4단계)
  - `.unsupported` → 시작 버튼 비활성 + 문구
- 방출된 묶음을 순서대로 `translate(_:)`에 넘기고 결과를 번역 목록에 추가. 번역은 하나씩 순차 처리한다(앞 묶음이 끝나기 전에 다음 묶음이 오면 대기)
- 화면: 묶음마다 [원문 묶음 / 번역] 한 쌍을 시간순으로 누적. 텍스트는 선택·복사 가능(`textSelection(.enabled)`)

완료 확인: 설치된 언어쌍으로 1분 넘게 말하면 약 30초마다 번역 블록이 붙고, 중지하면 남은 부분도 번역된다.

### 4단계 — 번역 언어팩 설치

- 언어쌍 상태가 `.supported`면 `ContentView`에 `.translationTask(configuration)`를 걸고 클로저 안에서 `session.prepareTranslation()`을 호출해 시스템 다운로드 시트를 띄운다
- 설치가 끝나면 상태를 다시 확인해 시작을 허용한다

완료 확인: 설치 안 된 언어쌍을 고르면 다운로드 안내가 뜨고, 설치 후 3단계 흐름이 동작한다.

## 이번 범위에서 제외 (확인된 요구가 생기면 추가)

- 시스템 오디오 캡처 (ScreenCaptureKit)
- 플로팅 자막 창, 메뉴바 앱
- 파일 내보내기 (.txt/.md), 세션 저장·불러오기
- 원문 언어 자동 감지
- Foundation Models 엔진 및 엔진 전환
- 화자 분리, 문장 단위 실시간 번역, 30초 값 설정 UI
- macOS 26 이하 지원, 앱 서명·공증·배포

## 확인이 필요한 위험

| 위험 | 확인 시점 | 대응 |
|---|---|---|
| 전사 언어와 번역 언어쌍의 지원 범위가 다름 | 1·3단계 | 지원 안 되는 쌍은 시작 비활성 |
| 음성 모델·번역 언어팩 첫 다운로드 시간 | 2·4단계 | 다운로드 중 상태 문구만 표시 |
| 30초 동안 말이 거의 없으면 묶음이 늦게 나감 | 3단계 실행 | 요구 그대로 둠. 불편이 확인되면 그때 상한 시간 검토 |
| Sandbox에서 마이크 권한이 엔타이틀먼트 없이 거부됨 | 1·2단계 | `device.audio-input` 엔타이틀먼트로 처리 |
