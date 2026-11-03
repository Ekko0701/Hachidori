# ProxyBoy — 작업 계획

macOS용 HTTP/HTTPS 트래픽 디버깅 프록시 (Proxyman 유형).
앱/웹 개발 시 요청·응답을 가로채 검사하는 도구.

- **플랫폼**: macOS 26+, Swift 6.3, SwiftUI (필요 시 AppKit 브릿지)
- **디자인 방향**: GitKraken / Fork 스타일의 밀도 높은 3-패널 레이아웃 + macOS 네이티브 컴포넌트 우선
- **배포 방향**: GitHub + Homebrew(cask), Developer ID 서명 + 공증(notarization), 비-App Store
  (App Store 샌드박스는 시스템 프록시 변경·인증서 설치와 충돌 → 배제)

> **진행 현황 (2026-09-04)**: Phase 0~2 완료. HTTP + **HTTPS(TLS MITM)** 가로채기 동작.
> SPM 패키지(`ProxyCore` + `ProxyBoyApp`). `swift test` 통과, `curl -x`로 실제
> `https://example.com`·`httpbin.org` 복호화·캡처 검증(헤드리스 `ProxyBoy --serve`).
> 실기기 지원: 프록시 LAN 바인딩(0.0.0.0) + Mac IP 표시 + 기기용 CA 배포 포털(`http://proxyboy.local` → HTML/iOS `.mobileconfig`/`.crt`).
> Phase 3 완료: macOS 시스템 프록시 자동설정·원복(`SystemProxyConfigurator`), iOS 프로파일 생성.
> WebSocket 완료: ws/wss 투명 릴레이 + 프레임 스니퍼로 메시지 캡처(로컬 e2e 검증).
> **Phase 4 완료 (2026-11-03)**: 고밀도 리스트(Type/Size/Duration 열, 메서드·상태 색상, 호스트 그룹핑, 메서드/상태/타입 필터),
> 인스펙터 Overview/Request/Response/Timing 탭, JSON·HTML/XML·JS/CSS 구문 강조, 이미지·HTML 미리보기, Hex 뷰,
> gzip/deflate/br 자동 해제(표시용), cURL 복사, 타이밍 워터폴(connect/TTFB/download). 다음: Phase 5(영속화·HAR)/Phase 7(배포).

---

## 1. 아키텍처 개요

```
 ┌──────────────┐    시스템 프록시 설정    ┌────────────────────────────┐
 │  대상 트래픽   │ ───────────────────▶ │        ProxyBoy 앱          │
 │ (앱/브라우저)  │                       │                            │
 └──────────────┘                       │  ┌──────────────────────┐  │
                                        │  │  Proxy Engine (NIO)  │  │
        원 서버로 재전송 ◀───────────────┼──┤  - HTTP/1, HTTP/2     │  │
                                        │  │  - TLS 가로채기 (MITM) │  │
                                        │  └──────────┬───────────┘  │
                                        │             │ 트랜잭션 이벤트 │
                                        │  ┌──────────▼───────────┐  │
                                        │  │  Traffic Store        │  │
                                        │  │  (메모리 + SQLite)     │  │
                                        │  └──────────┬───────────┘  │
                                        │  ┌──────────▼───────────┐  │
                                        │  │  SwiftUI 3-패널 UI     │  │
                                        │  └──────────────────────┘  │
                                        └────────────────────────────┘
```

### 핵심 기술 스택
| 영역 | 선택 | 이유 |
|------|------|------|
| 프록시 엔진 | **SwiftNIO** (+ NIOSSL, NIOHTTP1/2) | 바이트 스트림·TLS를 완전 제어 가능한 네이티브 비동기 엔진 |
| 인증서 발급 | **swift-certificates** + **swift-crypto** | Root CA 생성 및 호스트별 leaf 인증서 동적 서명 (Apple 공식) |
| 저장소 | **GRDB** (SQLite) 또는 SwiftData | 라이브 뷰는 메모리, 이력은 SQLite. 대용량 body는 파일 오프로드 |
| UI | **SwiftUI** `NavigationSplitView` / `Table` | 네이티브 3-패널, 검색·인스펙터 기본 제공 |
| 시스템 프록시 | `networksetup` / SystemConfiguration | 시작 시 자동 설정, 종료 시 원복 |

---

## 2. MITM 동작 원리 (구현 핵심)

1. **HTTP (평문)**: 요청 파싱 → 원 서버로 포워딩 → 응답 릴레이하며 로깅.
2. **HTTPS**: 클라이언트가 `CONNECT host:443` 전송 → 프록시가 `200 Established` 응답 →
   - 클라이언트 쪽: 프록시가 **서버 역할**로 TLS 핸드셰이크 (Root CA로 서명한 호스트별 leaf 인증서 제시)
   - 서버 쪽: 프록시가 **클라이언트 역할**로 실제 원 서버에 별도 TLS 연결
   - 중간에서 복호화 → 로깅 → 재암호화하여 릴레이
3. **신뢰 확보**: 자체 Root CA를 시스템 키체인에 설치하고 "항상 신뢰"로 지정해야 클라이언트가 leaf 인증서를 신뢰함 (관리자 인증 필요).

---

## 3. 단계별 작업 계획

### Phase 0 — 프로젝트 스캐폴딩 ✅ 완료
- [x] SPM 패키지 생성 (`ProxyCore` 라이브러리 + `ProxyBoyApp` SwiftUI 앱, Swift 6)
- [x] swift-nio 의존성 추가 (SSL/certificates/GRDB는 해당 Phase에서 추가)
- [x] 3-패널 UI (사이드바·요청 테이블·상세 인스펙터) — 실데이터 연동
- [ ] 엔타이틀먼트/서명 설정 (하드닝 런타임, 네트워크 클라이언트/서버) → 배포 Phase로 이동

### Phase 1 — 프록시 엔진: HTTP ✅ 완료
- [x] NIO 기반 TCP 리스너 (기본 포트 9090, 0이면 임의 포트)
- [x] HTTP/1 요청/응답 파싱 및 원 서버 포워딩 (버퍼링 방식)
- [x] 트랜잭션 모델 정의 및 `AsyncStream`으로 앱에 방출
- [x] 검증: 통합 테스트(클라이언트→프록시→오리진→캡처) 통과. 수동: `curl -x http://127.0.0.1:9090 http://example.com`

### Phase 2 — HTTPS 가로채기 ✅ 완료
- [x] swift-certificates로 Root CA 생성/영속 (`CertificateAuthority`, 앱 지원 폴더에 PEM 저장 — Keychain 이전은 후속)
- [x] 호스트별 leaf 인증서 동적 발급 + NIOSSLContext 캐싱
- [x] `CONNECT` 처리, 양방향 TLS 종단 (leaf=서버역 / 원서버=클라역, 원서버 인증서 검증 유지)
- [x] 복호화된 요청/응답 로깅 (ALPN http/1.1 고정)
- [x] 검증: `ProxyBoy --serve` + `curl -x ... https://example.com --cacert rootCA.pem` → 200, 본문 복호화 확인
- 알려진 이슈: 200 응답 chunked 프레이밍이 터널 TLS를 깨뜨림 → `Content-Length: 0` 명시 + 파이프라인 교체 중 autoRead 일시정지로 해결

### Phase 3 — 시스템 통합 & 인증서 설치 UX ✅ 완료
- [x] 녹화 시작 시 시스템 프록시 자동 설정, 중지·종료(willTerminate) 시 **원복** (`SystemProxyConfigurator`)
- [x] Root CA 설치 가이드 + 기기 포털(`proxyboy.local`: HTML/`.mobileconfig`/`.crt`), 상태 표시
- [x] 녹화/초기화 토글, 상태 인디케이터, 실기기(LAN) 토글
- [ ] (후속) 키체인 자동 신뢰(관리자 헬퍼)는 미구현 — 현재는 수동 신뢰

### Phase 4 — 검사 UI 본격 구축 ✅ 완료
- [x] 라이브 스트리밍 요청 리스트 (`Table`: 메서드·상태·호스트·경로·타입·크기·소요시간·시각, 교차 행 배경, `.controlSize(.small)`)
- [x] 상세 인스펙터 탭: Overview / Request / Response / Timing (+ WebSocket Messages). 탭·본문 보기 모드는 선택 간 유지
- [x] JSON pretty-print + 구문 강조(`SyntaxHighlighter`: JSON/XML·HTML/JS·CSS), 이미지·HTML(WKWebView, JS 비활성) 미리보기, Hex 뷰, 헤더 표(교차 배경·복사)
- [x] 검색(URL/메서드/상태)·메서드/상태클래스/콘텐츠타입 필터, 메서드/상태코드 색상, 호스트별 그룹핑(`DisclosureTableRow`)
- [x] GitKraken/Fork 감성: 고밀도 리스트 + 모노스페이스 코드 뷰
- [x] 타이밍: `TransactionTiming`(connectStarted/connected/requestSent/firstByte/responseReceived/completed) 엔진 기록 + 워터폴 뷰
- [x] (Phase 5 선반영) 표시용 gzip/deflate/br 자동 해제(`BodyDecoder`, Compression 프레임워크), cURL 복사
- 개발용 플래그: `ProxyBoy --record`(시스템 프록시 변경 없이 즉시 녹화), `--snapshot-dir <dir>`(cmd.txt로 UI 구동·PNG 렌더)

### Phase 5 — 저장 & 편의 기능 (1주)
- [ ] SQLite 영속화, 대용량 body 파일 오프로드, 세션 이력
- [x] gzip/brotli/deflate 자동 압축 해제 (표시용, Phase 4에서 선반영)
- [ ] HAR 내보내기, 컬럼 커스터마이즈 (cURL 복사는 완료)

### Phase 6 — 고급 기능 (선택·우선순위별)
- [x] WebSocket(ws/wss) 투명 릴레이 + 프레임 캡처 (메시지 탭). HTTP/2는 미지원
- [ ] HTTP/2 지원
- [x] **Map Local(목 응답) + Rewrite(상태/헤더/본문 수정) 규칙** — 규칙 기반 오버라이드(`OverrideRule`/`RuleStore`), Rules 시트 UI, e2e 검증. 본문 교체 시 원서버 `Content-Encoding` 제거(압축 응답에도 안전, 2026-11-03)
- [x] **Breakpoint (요청·응답 일시정지 후 편집/Abort)** — `BreakpointController`. 요청(메서드·헤더·바디)은 오리진 전, 응답(상태·헤더·바디)은 클라이언트 전 일시정지. Send Edited/Send Original/Abort. 압축 응답은 편집기에 디코딩된 본문으로 표시(`decodedForEditing`). e2e 검증
- [ ] Compose/Replay(요청 재전송)
- [ ] 네트워크 스로틀링, 프로세스별 트래픽 귀속

### Phase 7 — 배포 (0.5주)
- [ ] Developer ID 서명 + 공증, 하드닝 런타임
- [ ] 인증서/프록시 설정용 권한 헬퍼(SMAppService) 필요 여부 검토
- [ ] DMG 패키징

---

## 4. 주요 리스크 & 결정 사항

| 항목 | 리스크/결정 | 권장 |
|------|-------------|------|
| 샌드박스/배포 | App Store 샌드박스가 프록시·인증서 설치와 충돌 | Developer ID 직접 배포로 시작 |
| 시스템 프록시 원복 | 크래시 시 사용자 네트워크가 프록시에 묶여 끊길 수 있음 | 원복 로직 최우선, 종료 훅·복구 로직 필수 |
| HTTP/2·QUIC | 복잡도 큼. HTTP/3(QUIC)는 UDP라 CONNECT 프록시로 안 잡힘 | MVP는 HTTP/1.1, 이후 HTTP/2. QUIC는 후순위 |
| 인증서 신뢰 | 시스템 키체인 신뢰 설정에 관리자 권한 필요 | 가이드 UX + 명확한 상태 표시 |
| 앱별 트래픽 귀속 | 연결→프로세스 매핑이 macOS에서 까다로움 | 후순위, 초기엔 호스트 기준 그룹핑 |

---

## 5. MVP 정의 (권장 1차 목표)

**"브라우저/앱의 HTTP·HTTPS 트래픽을 3-패널 UI에서 실시간으로 보고 요청·응답 본문을 검사"**
= Phase 0~4 완료 지점. 여기까지가 Proxyman의 가장 핵심적인 사용 경험.

예상 소요: 약 6~7주 (1인 기준, 러프 추정)
