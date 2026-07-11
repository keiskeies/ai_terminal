<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>자연어로 서버를 제어하세요. AI가 명령을 대신 실행합니다.</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top" target="_blank">🌐 웹사이트</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/releases" target="_blank">📦 다운로드</a> ·
    <a href="./QUESTION.md">❓ FAQ</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Platform" />
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License" />
    <img src="https://img.shields.io/badge/version-1.3.5-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**🌍 언어:**
[中文](./README.md) | [English](./README_EN.md) | [日本語](./README_JA.md) | [Deutsch](./README_DE.md) | [Français](./README_FR.md) | [Español](./README_ES.md) | **한국어** | [Русский](./README_RU.md) | [Português](./README_PT.md) | [Italiano](./README_IT.md)

---

## 한 문장으로 설명하기

> **터미널을 써본 적 없나요? 괜찮습니다.** AI Terminal을 열고 원하는 것을 평범한 한국어로 말해보세요 — 서버에 연결하고, 명령을 실행하고, 소프트웨어를 설치하고, 문제를 해결해줍니다. 모두 안전하며 당신의 통제 하에 있습니다.

## 🎯 공감 가시나요?

### 😫 초보자 / 비기술 사용자

- VPS를 빌렸는데 터미널을 열고 **검은 화면**만 쳐다보며 뭘 입력해야 할지 모르겠다
- 친구가 "그냥 Nginx 설치해" 라고 했는데 — 구글에서 튜토리얼을 10개나 찾았는데 명령어가 다 다르다
- Java를 설정하려다 `PATH`를 잘못 건드려서 터미널 전체가 망가졌다
- 서버 취약점에 대해 경고했는데 — 확인하는 방법도 모르겠다
- 3시간 동안 이것저것 해봤는데 아무것도 안 된다. 이제 지쳤다.

### 👨‍💻 개발자

- 매번 똑같은 `chmod` / `systemctl` 명령어를 구글에서 찾는다
- 서버에 SSH 접속했는데 정확한 `grep` 플래그가 기억이 안 난다
- 로그를 확인하고 싶은가? 6개월 전 북마크를 먼저 찾아야 한다
- 브라우저 탭이 15개나 열려있고 서버를 왔다 갔다 하면서 뭐가 어딨는지 헷갈린다

### 🔧 DevOps / 시스템 관리자

- 10대 서버에 똑같은 소프트웨어? 각 서버에 SSH 접속해서 반복한다. 또 다시.
- "누가 설정을 바꿨지?" — 아무도 기억하지 않고 기록도 없다
- 신입 사원이 "환경은 어떻게 설정하나요?" 라고 물어보는데 — 이번 달만 5번째 설명한다
- 일괄 건강 검사를 하고 싶은가? 스크립트를 작성하는 게 직접 하는 것보다 오래 걸린다

### 🧑‍💼 제품 관리자 / 1인 창업자

- 유일한 개발자가 떠났다. 서버는 이제 블랙박스다.
- 데이터를 확인해야 하는데 SQL을 못 쓴다. 다른 사람에게 물어봐야 한다.
- 설정 변경을 배포하려면 개발 스프린트가 필요하다. 겨우 한 줄짜리인데.
- 역할이 5개나 된다. `vi` 배울 시간이 없다.

**위의 모든 상황? AI Terminal에 한 문장 말하면 해결됩니다.**

## 🆕 v1.3.5의 새로운 기능

v1.3.5는 **5가지 새로운 핵심 기능**을 탑재한 주요 업데이트입니다: 서버 모니터링, 변경 기록, Ops 런북, 알림 센터, 글래스몰피즘 UI — DevOps 효율성을 위한 완전한 업그레이드.

### 📊 실시간 서버 모니터링 대시보드

> 이제 `top`, `df`, `free`를 직접 입력할 필요 없습니다 — 모든 지표를 한눈에

| 실시간 모니터링 개요 | 호스트별 토글 |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

- **CPU / 메모리 / 디스크 / 네트워크** — 4가지 핵심 지표 실시간 새로고침
- **멀티 호스트 병렬 모니터링** — 하나의 대시보드에서 모든 서버 확인
- **호스트별 독립 토글** — 언제든 원하는 머신의 모니터링 끄기
- 이상 지표 자동 강조 — 문제를 즉시 발견

### 📝 변경 기록 & 감사 로그

> 누가 무엇을 언제 바꿨나요? 완전히 추적 가능합니다. 사후 포렌식이 쉬워집니다.

- **모든 Agent 작업 자동 기록**: 명령 실행, 파일 변경, 설정 수정
- **변경 창 관리**: 계획된 변경 vs 긴급 변경, 분류 관리
- **완전한 감사 로그**: 작업자, 타임스탬프, 명령, 결과, 종료 코드 — 모두 조회 가능
- **롤백 제안**: AI가 변경 영향을 분석하고 롤백 계획을 추천

### 📋 Ops 런북

| 런북 목록 | 실행 중 |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

- **내장된 일반적인 Ops 템플릿**: 시스템 점검, 보안 강화, 로그 정리, 서비스 배포 등
- **원클릭 실행**: 더 이상 단계별로 명령어 입력할 필요 없음 — 런북이 자동으로 실행
- **멀티 호스트 오케스트레이션**: 여러 서버에서 동일한 워크플로우를 병렬 또는 순차적으로 실행
- **사용자 정의 런북**: 자신만의 Ops 플레이북을 만들고 팀 지식을 코드화

### 🔔 알림 센터

- **작업 완료 알림** — 장시간 실행되는 작업이 끝나는 순간 알림 받기
- **이상 알림** — 모니터링 임계값 초과, 명령 실패, 즉시 푸시
- **보안 알림** — 고위험 작업, 의심스러운 행동, 조기 경고
- **설정 가능한 알림 정책** — 어떤 이벤트가 알림을 트리거할지 당신이 결정

### 🎨 글래스몰피즘 UI 리디자인

| 설정 (중국어) | 설정 (영어) |
|:---:|:---:|
| <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面_英文版.jpg" width="400" /> |

- 시각적 계층이 더 명확한 **GlassCard 글래스몰피즘 카드 디자인**
- **테마 시스템 리팩토링** — 사용자 정의 테마 색상, 모서리 반경, 블러 강도
- 더 부드러운 애니메이션 전환, 더 정교한 상호작용 피드백
- **15+ 언어** 원클릭 전환

| 다국어 설정 |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

## 💡 당신을 위해 무엇을 할 수 있나요?

### 소프트웨어 설치? 그냥 말만 하세요.

> 💬 "이 서버에 Docker 설치해줘"

AI가 OS 버전을 감지하고 공식 문서와 매칭하여 설치 명령을 실행하고 제대로 작동하는지 확인합니다. 외울 명령어 제로.

### 환경 설정? 이제 PATH 골치 아플 일 없습니다.

> 💬 "Python 3.12 환경변수 제대로 설정해줘"

AI는 Debian은 `apt`를, CentOS는 `yum`을, macOS는 `brew`를 쓴다는 걸 압니다. 추측하지 않습니다 — 공식 문서를 엄격히 따릅니다.

### 취약점 확인? 당신보다 더 꼼꼼합니다.

> 💬 "서버 보안 문제 스캔해줘"

AI가 시스템 업데이트 확인, 포트 스캔, 프로세스 감사를 자동으로 실행합니다. 무엇을 고쳐야 할지 전체 보고서를 받습니다.

### 로그 읽기? 더 이상 북마크를 뒤질 필요 없습니다.

> 💬 "최근 Nginx 에러 보여줘"

AI는 로그가 어디에 있는지, 어떻게 필터링하는지, 무엇이 중요한지 압니다. 핵심 정보만, `tail -f` gymnastics 없이.

### 서버 관리? 여러 머신, 하나의 인터페이스.

연결 풀링이 있는 SSH 원격 연결. 제로 딜레이로 서버 간 전환. 여러 탭, 하나의 공유 연결.

## 🛡️ 보안: 방 안의 코끼리

서버를 AI에 맡긴다는 건 무섭게 들립니다. 세 가지 타당한 우려:

### 🔐 "비밀번호는 어디로 가나요?"

```
당신의 비밀번호 → 시스템 레벨 보안 저장소 (macOS Keychain / Android Keystore)
                       ↓
              로컬 데이터베이스에는 "어느 키를 사용했는지"만 저장될 뿐, 비밀번호 자체는 절대 저장하지 않음
                       ↓
              비밀번호는 로그, 설정 파일, 디스크 어디에도 평문으로 나타나지 않음
```

누군가 당신의 기기를 훔쳐도, 생체인식/암호 없이는 암호화된 쓰레기 값만 얻을 뿐입니다.

### 🤖 "AI가 제멋대로 행동할 수 있나요?"

**아니요.** 세 겹의 방어막:

```
┌─────────────────────────────────────────────────────┐
│ 1단계: 행동 경계 프롬프트                            │
│ AI 시스템 지침에서 명시적으로 금지:                   │
│   ✗ 묻지 않고 소프트웨어 설치/제거                    │
│   ✗ 환경 변수나 시스템 설정 수정                       │
│   ✗ 파괴적인 작업 실행                                │
│   ✓ "확인/점검" 요청 → 읽기 전용 명령                │
│   ✓ 문제 발견 → 먼저 보고, 절대 스스로 고치지 않음    │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ 2단계: SafetyGuard 명령 분류                         │
│ 모든 명령은 실행 전에 검토됩니다:                     │
│   🔴 차단 → 즉시 차단, 절대 실행되지 않음             │
│      (rm -rf /, chmod 777, 디스크 포맷 등)            │
│   🟡 경고 → 팝업 경고, 확인 입력 필요                 │
│      (apt install, systemctl stop, 방화벽 변경)       │
│   🔵 정보 → 저위험 안내, 정상 실행                    │
│      (curl, wget, ls, cat 등)                        │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ 3단계: 당신이 최종 관문입니다                        │
│ 당신은 항상 마지막 방어선입니다.                      │
│ 경고 레벨 명령은 확인 없이는 실행되지 않습니다.        │
│ 언제든 중단, 취소, 검토할 수 있습니다.                │
└─────────────────────────────────────────────────────┘
```

### 📋 Agent 행동 헌장

| 요청할 수 있는 것 | AI가 할 일 | AI가 하지 않을 일 |
|:---|:---|:---|
| 소프트웨어 설치 | 공식 설치 명령 생성 및 실행 | 스스로 설치할 버전을 결정 |
| 보안 확인 | 감사 명령 실행 및 결과 보고 | 허가 없이 문제를 수정 |
| 환경 설정 | 공식 문서를 정확히 따름 | 요청하지 않은 시스템 파라미터 변경 |
| 로그 읽기 | 필터링 및 핵심 정보 표시 | 로그 파일 삭제 또는 수정 |
| 서비스 관리 | 지정한 서비스 시작/중지 | 언급하지 않은 다른 서비스 시작 |
| 워크플로우 실행 | 사전 정의된 단계 자동 실행 | 중요 단계 건너뛰기 또는 프로세스 수정 |

**요약: AI는 당신의 비서이지 상사가 아닙니다. 당신이 요청한 일을 합니다. 그 이상은 없습니다.**

## ✨ 핵심 기능

| 기능 | 설명 |
|:---|:---|
| 🤖 **Agent 자동 실행** | AI가 명령을 생성하고 작업이 완료될 때까지 루프로 실행 |
| 📊 **서버 모니터링** | 실시간 CPU/메모리/디스크/네트워크 대시보드, 멀티 호스트 병렬 |
| 📝 **변경 기록** | 완전한 감사 로그, 추적 가능한 작업, 롤백 준비 |
| 📋 **Ops 런북** | 내장된 런북 템플릿, 원클릭 일반적인 Ops 작업 |
| 🔔 **알림 센터** | 작업 완료, 이상 알림, 보안 알림 — 즉시 푸시 |
| 🛡️ **삼중 보안** | 행동 경계 프롬프트 → SafetyGuard 명령 분류 → 위험한 작업은 확인 필요 |
| 🔐 **제로 평문 자격 증명** | 비밀번호/개인 키는 시스템 Keychain / Keystore에 저장, 디스크에 평문으로 저장되지 않음 |
| 🖥️ **5가지 네이티브 플랫폼** | macOS / Linux / Windows / Android / iOS — 완전한 네이티브 지원 |
| 📡 **로컬 + 원격** | SSH 원격 연결 + 로컬 PTY 터미널; Agent는 두 모드 모두에서 작동 |
| 🔄 **연결 풀** | SSH 연결 풀링 — 여러 탭이 하나의 연결을 공유, 제로 딜레이 전환 |
| 🌊 **스트리밍 출력** | AI 응답이 실시간으로 렌더링; 터미널 출력이 라이브 스트리밍 |
| 🧠 **지식 기반** | 150+ 소프트웨어 설치/설정 가이드 내장 — 공식 문서를 따르며 AI 환각 없음 |
| 🌐 **20+ 제공업체** | DeepSeek / Qwen / Claude / Gemini / Ollama 등, 원격 설정 업데이트 지원 |
| 🌍 **15+ 언어** | 중국어 / 영어 / 일본어 / 한국어 / 프랑스어 / 독일어 / 스페인어 / 러시아어 / 포르투갈어 등 |

## 🏗️ 기술 스택

```
Flutter 3.16+ (Dart 3.2+)
├── 상태 관리: Riverpod
├── 라우팅: GoRouter
├── 로컬 저장소: Hive + flutter_secure_storage
├── SSH: dartssh2
├── 로컬 터미널: flutter_pty
├── 터미널 UI: xterm.dart
├── AI 인터페이스: OpenAI 호환 (20+ 제공업체)
├── 모니터링: 서버 대시보드 (CPU/메모리/디스크/네트워크)
├── Ops: 변경 기록 + 감사 로그 + 런북 워크플로우
└── UI: GlassCard 글래스몰피즘 + 멀티 테마 + 15+ 언어
```

## 🚀 시작하기

### 전제 조건

- Flutter 3.16.0+
- Dart 3.2.0+
- 플랫폼별 개발 도구 (Xcode / Android Studio / VS Code 등)

### 설치 및 실행

```bash
# 리포지토리 클론
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

# 의존성 설치
flutter pub get

# Hive 어댑터 생성 (처음 한 번만)
dart run build_runner build --delete-conflicting-outputs

# 실행
flutter run
```

### 릴리즈 빌드

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android APK
flutter build apk --release

# iOS (macOS + 개발자 인증서 필요)
flutter build ios --release
```

> 📥 또는 [Releases](https://github.com/keiskeies/ai_terminal/releases)에서 미리 빌드된 바이너리를 다운로드하세요.

## 🔧 AI 모델 설정

앱에는 **20+ AI 제공업체 프리셋**이 있으며 모든 **OpenAI 호환 API**를 지원합니다:

| 카테고리 | 제공업체 |
|:---|:---|
| 🏠 로컬 | Ollama (완전 무료, API 키 필요 없음) |
| 🇨🇳 중국 클라우드 | DeepSeek / Qwen / GLM / Kimi / Doubao / MiMo / MiniMax / SiliconFlow / StepFun / Baichuan / Spark / Hunyuan |
| 🌍 글로벌 클라우드 | OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq |
| 🔧 커스텀 | 모든 OpenAI 호환 API 엔드포인트 |

설정 단계:

1. 앱 열기 → 설정 → AI 모델 설정
2. `+`를 클릭하여 모델 추가
3. 제공업체 선택 (Base URL과 추천 모델이 자동 입력됨)
4. API 키를 입력하고 모델 선택
5. 기본 모델로 설정

> 💡 제공업체 목록은 원격 업데이트를 지원합니다: 제공업체 드롭다운 옆의 🔄 버튼을 클릭하면 서버에서 최신 제공업체와 모델을 가져옵니다 — 앱 업데이트 필요 없음

## 📱 스크린샷

| 메인 UI (모니터 + 터미널) | 멀티 호스트 오케스트레이션 |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

| Ops 런북 | 설정 페이지 |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

| 다국어 설정 |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

> 🤖 AI 기능은 <b>Xiaomi MiMo</b> LLM으로 구동됩니다

## 📖 데모: 지식 기반 자동 설치

v1.3.0에서는 **명령 매뉴얼 지식 베이스**를 도입했습니다 — 150+ 공식 설치/제거/업데이트 가이드. Agent가 자동으로 지식 베이스와 매칭하고 공식 방법을 엄격히 따라 **AI 환각을 제거합니다**.

아래: Ubuntu 서버에 SSH 접속 후 "install openclaw" 입력:

| ① 명령 입력 | ② 지식 베이스 매칭, 명령 생성 |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_1.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_2.webp" width="400" /> |

| ③ 설치 자동 실행 | ④ 설치 확인 |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_3.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_4.webp" width="400" /> |

**흐름 분석:**

1. 사용자가 "install openclaw" 입력 → Agent가 작업(install)과 플랫폼(linux) 추출
2. 지식 베이스가 `linux-debian`용 `openclaw` 매칭 (엄격 모드), 공식 설치 명령 주입
3. Agent가 지식 베이스를 정확히 따름: Node.js 22 설치 후 `npm install -g openclaw`
4. 설치 후 확인: `openclaw --version` 실행하여 성공 확인

> 💡 지식 베이스는 플랫폼별 매칭을 지원합니다 (`linux-debian` vs `linux-rhel`은 다른 패키지 관리자 명령을 사용), 원클릭 원격 업데이트 지원

## 🗺️ 로드맵

- [x] v1.0.0 — 핵심 기능 릴리즈
  - [x] SSH 원격 터미널 + 로컬 PTY 터미널
  - [x] AI 채팅 + 명령 생성 + 자동 실행
  - [x] SafetyGuard 명령 안전 검사
  - [x] 암호화된 자격 증명 저장
  - [x] 멀티 모델 설정
- [x] v1.1.0 — UI 개선
  - [x] AI 패널 레이아웃 리디자인
  - [x] 모바일 자동 방향 전환
  - [x] Agent 모드 그린 테마
- [x] v1.2.0 — Agent 지능 향상
  - [x] 작업 간 지속적인 대화 기록
  - [x] 쿼리 명령 출력이 더 이상 잘리지 않음
  - [x] 기본적으로 무제한 실행 단계
  - [x] SFTP 파일 관리 + 원격 편집
- [x] v1.3.0 — 지식 기반
  - [x] 🧠 SQLite FTS5 전문 검색 지식 베이스 (150+ 소프트웨어 가이드)
  - [x] 🔄 원격 지식 베이스 자동 동기화 (시작 시 GitHub에서 업데이트)
  - [x] 🎯 플랫폼별 매칭 (linux-debian / linux-rhel / macos)
  - [x] 🛡️ LLM 안전 규칙 (엄격한 시행 + 검색 명령 금지)
  - [x] 🔧 지식 베이스 빌드 도구 (CSV → SQLite)
  - [x] 💬 친절한 API 오류 메시지 (401/429/timeout)
- [x] v1.3.1 — 제공업체 생태계
  - [x] 🌐 20+ AI 제공업체 프리셋 (중국 12개 + 글로벌 8개 + Ollama + 커스텀)
  - [x] 🔄 원격 제공업체 설정 업데이트 (앱 업데이트 필요 없음)
  - [x] 🏷️ 제공업체 설명 및 가격 정보
  - [x] 🤖 프리셋 모델 빠른 선택 (원클릭)
  - [x] 🦙 Ollama 로컬 배포 (API 키 없음, 완전 무료)
  - [x] 📐 모델 추가 대화상자 최적화 (와이드 스크린 2열 레이아웃)
- [x] v1.3.5 — Ops 기능 메가 업그레이드
  - [x] 📊 실시간 서버 모니터링 (CPU/메모리/디스크/네트워크, 멀티 호스트 병렬)
  - [x] 📝 변경 기록 & 감사 로그 (완전한 작업 기록, 추적 가능 & 롤백 준비)
  - [x] 📋 Ops 런북 (내장 템플릿 + 커스텀, 원클릭 실행)
  - [x] 🔔 알림 센터 (작업 완료, 이상 알림, 보안 알림)
  - [x] 🎨 글래스몰피즘 UI 리디자인 (GlassCard 디자인, 테마 시스템 업그레이드)
  - [x] 🌍 15+ 언어 현지화
  - [x] 📺 멀티 호스트 오케스트레이션 (서버 간 워크플로우 병렬/순차 실행)

## 🤝 기여하기

기여를 환영합니다! 버그 리포트, 기능 제안, 또는 코드.

1. 이 리포지토리를 포크하세요
2. 기능 브랜치를 만드세요 (`git checkout -b feature/amazing-feature`)
3. 변경 사항을 커밋하세요 (`git commit -m 'Add amazing feature'`)
4. 브랜치에 푸시하세요 (`git push origin feature/amazing-feature`)
5. 풀 리퀘스트를 여세요

## 📄 라이선스

[MIT 라이선스](./LICENSE)

---

## ⭐ 스타 히스토리

[![Star History Chart](https://api.star-history.com/svg?repos=keiskeies/ai_terminal&type=Date)](https://star-history.com/#keiskeies/ai_terminal&Date)

---

<p align="center">
  이 프로젝트가 도움이 되었다면 ⭐ Star를 눌러주세요!
</p>
