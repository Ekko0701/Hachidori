# 실기기 테스트 가이드 — ProxyBoy로 API·WebView 응답 조작하기

실기기에서 빌드한 앱의 **자체 API 응답**과 **WebView 페이지 응답**을 ProxyBoy로
가로채 원하는 대로 바꿔 보는 절차입니다. 앱 코드를 고치지 않고도 서버 오류, 빈 데이터,
특정 필드 값, 다른 HTML 페이지 등을 시뮬레이션할 수 있습니다.

> 전제: Mac과 테스트 기기가 **같은 Wi-Fi**에 있어야 합니다. 회사 Wi-Fi가 기기 간 통신(AP isolation)을
> 막으면 Mac의 인터넷 공유나 개인 핫스팟으로 같은 망을 만들어야 합니다.

---

## 1. Mac 쪽 준비 (한 번만)

```bash
cd ~/Developer/personal/ProxyBoy
swift run ProxyBoy
```

1. 툴바 오른쪽 **Certificate**(자물쇠) 버튼을 누릅니다.
2. **Auto-configure macOS system proxy**는 꺼도 됩니다. Mac 자신의 트래픽까지 잡을 필요가 없으면
   끄는 쪽이 조용합니다. (켜 두면 Record 중 Mac 전체 트래픽도 리스트에 섞입니다.)
3. **Test on physical devices (LAN)** 토글을 켭니다. 아래에 Mac의 IP와 포트(기본 9090)가 표시됩니다.
   예: `192.168.0.12:9090`
4. 툴바 **Record**(⌘R)를 누릅니다. 왼쪽 아래 상태가 `Listening on 192.168.0.12:9090 · HTTP+HTTPS`로 바뀌어야 합니다.
   - LAN 토글을 Record 중에 바꿨다면 Stop 후 다시 Record 해야 반영됩니다.
5. macOS 방화벽이 켜져 있으면 처음 수신 시 "ProxyBoy가 들어오는 연결을 허용할까요?"를 물어봅니다. **허용**합니다.

## 2. 기기 쪽 준비 (기기당 한 번)

### 2-1. Wi-Fi 프록시 설정

- **iOS**: 설정 > Wi-Fi > 접속 중인 망의 ⓘ > HTTP 프록시 > **수동** > 서버 `Mac IP`, 포트 `9090`.
- **Android**: 설정 > Wi-Fi > 망 길게 누르기(또는 ⚙) > 수정 > 고급 > 프록시 **수동** > 호스트 `Mac IP`, 포트 `9090`.

이 시점부터 기기의 브라우저·앱 트래픽이 ProxyBoy 리스트에 나타나기 시작합니다. HTTPS는 아직
인증서 오류가 나므로 다음 단계가 필요합니다.

### 2-2. Root CA 설치 (HTTPS 복호화용)

프록시를 설정한 **뒤에** 기기 브라우저에서 아래 주소를 엽니다. 이 주소는 ProxyBoy 자신이
응답하므로 프록시 설정 전에는 열리지 않습니다.

```
http://proxyboy.local
```

- **iOS**
  1. "iOS profile (.mobileconfig)"를 눌러 프로파일을 내려받습니다.
  2. 설정 > 일반 > VPN 및 기기 관리 > 다운로드된 프로파일 > **설치**.
  3. **설정 > 일반 > 정보 > 인증서 신뢰 설정**에서 ProxyBoy Root CA를 **켭니다.**
     이 단계를 빠뜨리면 WKWebView와 URLSession 모두 HTTPS를 거부합니다.
- **Android**
  1. "Android / other (.crt)"를 눌러 내려받습니다.
  2. 설정 > 보안 > 암호화 및 사용자 인증 정보 > 인증서 설치 > CA 인증서 > 내려받은 파일 선택.
     (기기마다 메뉴 이름이 조금 다릅니다. "사용자 CA"로 설치됩니다.)
  3. **앱이 사용자 CA를 신뢰하도록 해야 합니다.** Android 7(API 24) 이상 앱은 기본적으로 사용자 CA를
     믿지 않습니다. 앱 **debug 빌드**의 `res/xml/network_security_config.xml`에 아래를 넣고
     `AndroidManifest.xml`의 `<application android:networkSecurityConfig="@xml/network_security_config">`로
     연결합니다. WebView도 이 설정을 따릅니다.

     ```xml
     <network-security-config>
         <debug-overrides>
             <trust-anchors>
                 <certificates src="system" />
                 <certificates src="user" />
             </trust-anchors>
         </debug-overrides>
     </network-security-config>
     ```

     `debug-overrides`는 debuggable 빌드에서만 적용되므로 운영 빌드에는 영향이 없습니다.

### 2-3. 확인

기기에서 테스트할 앱을 열고 아무 화면이나 들어갑니다. ProxyBoy 리스트에 `api.…` 같은 자체 API 호스트와
WebView 페이지 호스트가 자물쇠 아이콘(HTTPS)과 함께 나타나고, 상태가 `200`이면 준비 완료입니다.

- `ERR`나 `CONNECT` 실패가 보이면 CA 신뢰가 안 된 것입니다(2-2 다시 확인).
- 앱의 특정 호스트만 계속 실패하면 그 호스트에 **인증서 피닝**이 걸려 있는 것입니다. 피닝은 프록시로 우회할 수 없습니다.

## 3. 트래픽 읽기

- 왼쪽 **Hosts**에서 호스트를 누르면 그 호스트만 보입니다. API 호스트와 WebView 호스트를 번갈아 보기 편합니다.
- 상단 필터 바: **Method / Status / Type**. 예: Type=JSON이면 API만, Type=HTML이면 WebView 페이지만.
- 검색창에 경로 일부(`/v1/members`)나 상태코드(`401`)를 치면 즉시 걸러집니다.
- 행을 누르면 오른쪽 인스펙터에 **Overview / Request / Response / Timing** 탭이 열립니다.
  Response 본문은 **Pretty**(구문 강조) / **Raw** / **Preview**(이미지·HTML 렌더) / **Hex**로 볼 수 있습니다.
  gzip·br로 압축된 응답도 자동으로 풀어서 보여 줍니다.
- 행 우클릭 > **Copy as cURL**로 같은 요청을 터미널에서 재현할 수 있습니다.

이 단계에서 **조작할 URL의 정확한 경로**를 적어 두세요. 규칙은 URL 부분 문자열로 매칭합니다.

## 4. 응답 조작하기

세 가지 도구가 있고, 용도가 다릅니다.

| 도구 | 언제 쓰나 | 특징 |
|------|-----------|------|
| **Rewrite 규칙** | 같은 조작을 반복 재현할 때 | 실제 서버 응답을 받은 뒤 상태/헤더/본문을 바꿈. 자동 적용 |
| **Map Local 규칙** | 서버 없이(또는 서버 상태와 무관하게) 고정 응답을 주고 싶을 때 | 서버에 접속하지 않고 지정한 응답을 즉시 반환 |
| **Breakpoint** | 한 번만, 실제 값을 보고 손으로 고치고 싶을 때 | 요청/응답을 멈추고 편집 후 전송. 요청 쪽도 편집 가능 |

규칙은 툴바 **Rules**, 브레이크포인트는 툴바 **Breakpoints** 팝오버에서 설정합니다.

### 4-1. 매칭 규칙 (공통)

- **URL contains**: 절대 URL(`https://호스트/경로?쿼리`, 포트 제외)에 대한 대소문자 무시 **부분 문자열**입니다.
  `/v1/members/me`처럼 경로를 넣으면 됩니다. 비워 두면 모든 요청에 걸리므로 반드시 좁히세요.
- **Method**: 비우면 모든 메서드.
- 규칙이 여러 개면 **위에서부터 첫 번째로 맞는 규칙 하나만** 적용됩니다. 넓은 규칙은 아래에 두세요.
- 규칙은 **ProxyBoy를 종료하면 사라집니다**(영속화는 Phase 5 예정). 자주 쓰는 본문은 파일로 따로 보관하세요.
- 규칙 변경은 Record 중에도 즉시 반영됩니다. 앱에서 화면을 다시 당기거나(Pull to refresh) 재진입하면 됩니다.

### 4-2. 자체 API 조작 예시

**(a) 서버 오류 시뮬레이션 — 500 / 401 / 403**

Rules > + > 다음처럼 설정:

- URL contains: `/v1/members/me`
- Override status code: 켜고 `500`
- Override response body: 켜고 Content-Type `application/json`
  ```json
  {"code":"INTERNAL_ERROR","message":"테스트용 서버 오류"}
  ```

→ 앱의 오류 처리(토스트, 재시도 버튼, 로그아웃 분기 등)를 확인합니다. `401`로 바꾸면 토큰 만료 분기를 볼 수 있습니다.

**(b) 빈 목록 / 경계값**

- URL contains: `/v1/courses`
- Override response body: `{"items":[],"total":0}`

→ 빈 상태 UI, 페이징 종료 처리 확인. 반대로 Response 탭에서 실제 응답을 **Copy** 한 뒤 항목을 수백 개로
불려 붙여 넣으면 긴 목록 성능도 볼 수 있습니다.

**(c) 특정 필드만 바꾸기**

Rewrite는 본문을 **통째로** 교체합니다. 실제 응답에서 한두 필드만 바꾸려면:

1. 리스트에서 실제 응답을 선택 > Response 탭 > Pretty > **Copy**.
2. 규칙 본문에 붙여 넣고 원하는 필드만 수정(예: `"isPremium": true`, `"remainingDays": 0`).

**(d) 서버 없이 목(mock) 응답 — Map Local**

아직 서버에 없는 API를 앱에서 먼저 개발할 때:

- URL contains: `/v2/new-feature`
- **Map Local (don't contact server)** 켜기
- Status `200`, Response body에 기대 JSON 입력

→ 서버가 죽어 있거나 경로가 없어도 앱은 이 응답을 받습니다.

**(e) 느린 서버·타임아웃**

ProxyBoy에는 지연(throttling) 기능이 아직 없습니다. 대신 **Breakpoints > Pause responses**를 켜고
URL을 지정하면 응답이 멈춘 채로 대기하므로, 원하는 시간만큼 기다렸다가 **Send Original**을 누르거나
**Abort**로 연결을 끊어 타임아웃·네트워크 오류 분기를 테스트할 수 있습니다.

### 4-3. WebView 페이지 조작 예시

WebView 트래픽은 Type=HTML(페이지), JS, CSS, JSON(페이지 내부 fetch/XHR)으로 섞여 보입니다.

**(a) 페이지 전체를 다른 HTML로 교체**

- URL contains: `/webview/event-detail`
- Override response body 켜기, Content-Type `text/html; charset=utf-8`
  ```html
  <!doctype html><html><body>
  <h1>테스트 페이지</h1>
  <button onclick="window.location='myapp://close'">닫기 딥링크</button>
  </body></html>
  ```

→ JS 브리지·딥링크·뒤로가기 처리 등 네이티브 ↔ WebView 연동을 임의의 페이지로 검증할 수 있습니다.
압축된 원본(gzip/br)이라도 ProxyBoy가 `Content-Encoding`을 자동으로 정리하므로 그대로 교체하면 됩니다.

**(b) 페이지 안에서 호출하는 API만 조작**

페이지는 그대로 두고 그 안의 `fetch('/api/…')` 응답만 바꾸려면 4-2와 동일하게 해당 API 경로에 규칙을 겁니다.
WebView 내부 요청도 같은 프록시를 지나므로 구분 없이 동작합니다.

**(c) 에러 페이지 처리**

WebView 페이지 URL에 Override status `404` 또는 `500`을 걸면 앱의 WebView 오류 화면·재시도 UI를 확인할 수 있습니다.
`Abort`(Breakpoint)로 끊으면 "네트워크 오류" 분기가 됩니다.

**(d) 스크립트 주입으로 디버깅**

실제 HTML을 Response 탭에서 복사한 뒤 `</body>` 앞에 아래를 넣고 Rewrite 본문으로 사용하면,
WebView 안에서 일어나는 일을 화면에 띄워 볼 수 있습니다.

```html
<script>
window.onerror = function (m, s, l) { alert('JS error: ' + m + ' @' + l); };
console.log = (function (orig) { return function () { orig.apply(console, arguments); /* 필요 시 DOM에 출력 */ }; })(console.log);
</script>
```

### 4-4. Breakpoint로 즉석 편집

1. 툴바 **Breakpoints** > **Pause responses (before client)** 켜기 > URL contains에 경로 입력.
   (비워 두면 모든 응답이 멈춰서 앱이 먹통처럼 보이니 반드시 좁히세요.)
2. 앱에서 해당 화면 진입 → ProxyBoy에 편집 시트가 뜹니다. 압축 응답도 **풀린 평문**으로 보입니다.
3. 상태코드·헤더·본문을 고치고 **Send Edited**, 그대로 보내려면 **Send Original**, 끊으려면 **Abort**.
4. **Pause requests (before server)**를 켜면 앱이 서버로 보내는 요청의 메서드·헤더·바디를 먼저 고칠 수 있습니다.
   예: `Authorization` 헤더를 지워 보내 인증 실패 경로 확인, 요청 파라미터를 바꿔 서버 검증 확인.

편집 시트가 떠 있는 동안 앱은 응답을 기다립니다. 앱의 타임아웃(보통 10~30초)보다 오래 끌면 앱이 먼저 포기하므로,
천천히 편집하려면 본문을 미리 준비해 두세요.

## 5. 테스트 시나리오 체크리스트

| 시나리오 | 방법 |
|----------|------|
| 토큰 만료 → 재로그인 유도 | API에 Rewrite `401` + `{"code":"TOKEN_EXPIRED"}` |
| 서버 점검 | 모든 API 호스트(URL contains `api.`)에 Rewrite `503` |
| 빈 데이터 / 첫 사용자 | 목록 API 본문을 빈 배열로 |
| 비정상 데이터 | 필드 누락, `null`, 매우 긴 문자열, 이모지, 음수 등을 본문에 넣기 |
| JSON 파싱 실패 | 본문을 `{"broken":` 처럼 깨뜨리기 |
| 느린 네트워크 / 타임아웃 | Breakpoint로 응답 보류 후 Send Original 또는 Abort |
| WebView 오류 화면 | 페이지 URL에 `404`/`500` 또는 Abort |
| WebView ↔ 네이티브 브리지 | 페이지 HTML 교체 후 브리지 호출 버튼 삽입 |
| 신규 API 선행 개발 | Map Local로 목 응답 |
| 권한·등급별 UI | 프로필 API 응답의 등급 필드만 바꿔 각 분기 확인 |

## 6. 한계와 주의사항

- **인증서 피닝**이 걸린 호스트는 가로챌 수 없습니다. 테스트용 빌드에서 피닝을 끄는 플래그가 있다면 그것을 쓰세요.
- **네이티브 HTTP 클라이언트**: iOS URLSession, Android OkHttp/HttpURLConnection, WebView는 시스템 프록시를 따릅니다.
  Flutter의 Dart `HttpClient`는 **따르지 않으므로** 앱에 `HttpOverrides`(findProxy + badCertificateCallback)를 넣어야 합니다.
  React Native(fetch)는 OS 스택을 쓰므로 그대로 잡힙니다.
- **WebSocket**은 내용을 볼 수만 있고(Messages 탭) 바꿀 수 없습니다.
- **HTTP/3(QUIC)** 트래픽은 프록시로 오지 않지만, 프록시가 설정되면 OS가 자동으로 HTTP/1.1·2로 내려가므로 보통 문제 없습니다.
- 규칙 본문 교체는 **전체 교체**입니다. 부분 수정은 복사 → 수정 → 붙여넣기로 하거나 Breakpoint를 쓰세요.
- 규칙과 캡처는 **앱 종료 시 사라집니다.**
- 테스트가 끝나면 기기 Wi-Fi 프록시를 **반드시 "끔"으로 되돌리세요.** ProxyBoy를 끄면 기기는 인터넷이 안 됩니다.
  Mac의 시스템 프록시는 ProxyBoy가 Stop/종료 시 자동 원복합니다.
- Root CA(`~/Library/Application Support/ProxyBoy/rootCA.pem`)는 이 Mac에서 만든 개인 키입니다. 테스트 기기에만 설치하고
  외부에 공유하지 마세요. 테스트가 끝난 기기에서는 프로파일/CA를 삭제해도 됩니다.

## 7. 문제 해결

| 증상 | 확인할 것 |
|------|-----------|
| 리스트에 아무것도 안 뜸 | 기기 프록시 IP/포트, Mac과 같은 Wi-Fi인지, macOS 방화벽 허용, LAN 토글 후 Record 재시작 |
| `http://proxyboy.local`이 안 열림 | 프록시를 먼저 설정했는지(이 주소는 프록시가 응답함), Record 중인지 |
| HTTPS 호스트가 `ERR` / 앱만 실패 | iOS 전체 신뢰 설정, Android debug 빌드의 network_security_config, 피닝 여부 |
| 규칙을 켰는데 응답이 그대로 | URL contains 철자, 위쪽에 먼저 걸리는 다른 규칙, 규칙 Enabled 여부, 앱 캐시(화면 재진입) |
| WebView가 빈 화면 | Rewrite 본문의 Content-Type이 `text/html`인지, HTML이 완전한지 |
| 앱이 멈춘 듯함 | Breakpoint URL이 비어 모든 요청이 멈춤 → 팝오버에서 토글 끄기 또는 시트에서 Send Original |
| Mac 인터넷이 안 됨 | ProxyBoy가 비정상 종료돼 시스템 프록시가 남은 경우: 시스템 설정 > 네트워크 > 프록시에서 HTTP/HTTPS 프록시 해제 |
