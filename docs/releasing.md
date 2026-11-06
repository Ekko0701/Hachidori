# 릴리스 가이드

하치도리는 App Store 밖에서 배포합니다. 릴리스는 Developer ID로 서명하고 Apple 공증(notarization)을 받은 DMG이며, GitHub Releases에 올립니다.

`scripts/package.sh`가 유니버설(Apple silicon + Intel) 릴리스 빌드, `.app` 번들, 서명, 공증, DMG까지 한 번에 만듭니다. `v*` 태그를 푸시하면 GitHub Actions가 같은 스크립트로 빌드해 **초안(draft) 릴리스**를 만듭니다.

## 1. 한 번만 하는 준비

### 로컬 Mac

1. 키체인에 **Developer ID Application** 인증서가 있어야 합니다. 확인:

   ```bash
   security find-identity -v -p codesigning
   ```

2. 공증 자격 증명을 키체인에 저장합니다. 개인 개발자 계정은 App Store Connect API 키를 만들 수 없으므로 Apple ID와 **앱 암호**를 씁니다. 앱 암호는 [account.apple.com](https://account.apple.com)의 로그인 및 보안 → 앱 암호에서 만들고, `abcd-efgh-ijkl-mnop` 형태입니다. Apple ID 로그인 암호를 넣으면 401 오류가 납니다.

   ```bash
   xcrun notarytool store-credentials hachidori-notary --apple-id <Apple ID> --team-id 34JS69S5XZ
   ```

### GitHub Actions 시크릿

저장소 **Settings → Secrets and variables → Actions**에 다음을 넣습니다.

| 시크릿 | 값 |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | 키체인 접근에서 Developer ID 인증서와 개인키를 `.p12`로 내보낸 뒤 base64로 인코딩한 값 |
| `DEVELOPER_ID_P12_PASSWORD` | 그 `.p12`를 내보낼 때 정한 암호 |
| `KEYCHAIN_PASSWORD` | 아무 임의 문자열 (CI에서 임시 키체인을 잠그는 데만 씀) |
| `APPLE_ID` | 개발자 계정의 Apple ID 이메일 |
| `APPLE_APP_PASSWORD` | 위에서 만든 앱 암호 (CI용으로 따로 하나 더 만들어 두면 나중에 하나만 폐기할 수 있습니다) |
| `APPLE_TEAM_ID` | `34JS69S5XZ` |

`gh`로 넣을 수도 있습니다.

```bash
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64
```

```bash
gh secret set APPLE_APP_PASSWORD
```

마지막 명령은 값을 물어보므로, 앱 암호를 붙여넣고 Enter를 누릅니다.

## 2. 릴리스 절차

1. `swift test`가 통과하는지 확인합니다.
2. 버전을 정합니다. 정식 공개 전까지는 `0.x`를 씁니다.
3. 태그를 푸시합니다.

   ```bash
   git tag v0.1.0
   ```

   ```bash
   git push origin v0.1.0
   ```

4. Actions의 **Release** 워크플로가 끝나면 Releases에 초안이 생깁니다. 릴리스 노트를 다듬고 **Publish**를 누릅니다. `0.x` 버전은 **Pre-release**로 표시됩니다.

로컬에서 직접 만들 때:

```bash
NOTARY_PROFILE=hachidori-notary scripts/package.sh 0.1.0
```

결과물은 `dist/Hachidori.app`, `dist/Hachidori-0.1.0.dmg`, `dist/Hachidori-0.1.0.dmg.sha256`입니다. `NOTARY_PROFILE` 없이 실행하면 서명만 하고 공증은 건너뜁니다. 그 DMG는 다른 Mac에서 Gatekeeper가 막습니다.

## 3. 게시 전 수동 확인

하치도리를 한 번도 설치하지 않은 Mac이나 새 사용자 계정에서 확인합니다.

- DMG를 열고 앱을 응용 프로그램으로 옮긴 뒤, 경고 없이 실행되는지 봅니다.
- **Record**를 누르면 시스템 설정의 프록시가 켜지고, **Stop**이나 종료 시 원래대로 돌아오는지 봅니다.
- 녹화 중에 강제 종료(`kill -9`)한 뒤 다시 실행하면 프록시 설정이 복구되는지 봅니다.
- Root CA를 신뢰한 뒤 HTTPS 요청이 복호화되어 보이는지 봅니다.

## 4. Homebrew cask (첫 공개 릴리스 후)

본인 탭 저장소 `Ekko0701/homebrew-tap`에 `Casks/hachidori.rb`를 만듭니다. `sha256`은 릴리스의 `.dmg.sha256` 값입니다.

```ruby
cask "hachidori" do
  version "0.1.0"
  sha256 "<dmg sha256>"

  url "https://github.com/Ekko0701/Hachidori/releases/download/v#{version}/Hachidori-#{version}.dmg"
  name "Hachidori"
  desc "HTTP/HTTPS debugging proxy"
  homepage "https://github.com/Ekko0701/Hachidori"

  depends_on macos: ">= :sonoma"

  app "Hachidori.app"

  zap trash: [
    "~/Library/Application Support/Hachidori",
    "~/Library/Preferences/com.ekko0701.hachidori.plist",
  ]
end
```

사용자는 다음으로 설치합니다.

```bash
brew install --cask ekko0701/tap/hachidori
```

## 알아둘 점

- 번들 ID는 `com.ekko0701.hachidori`입니다(`Packaging/Info.plist`). 바꾸면 사용자 설정 저장 위치가 바뀌므로 공개 후에는 바꾸지 않습니다.
- 패키징한 앱은 설정을 번들 ID 도메인에 저장합니다. `swift run`으로 띄운 개발 빌드의 설정(창 크기 등)과는 따로 저장됩니다. Root CA는 둘이 같은 `~/Library/Application Support/Hachidori`를 씁니다.
- `--record`, `--lan`, `--port`, `--snapshot-dir` 같은 개발용 플래그는 디버그 빌드에만 들어갑니다.
