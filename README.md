# MochiLog Mac

MochiLogのiOS/iPadOS 27向けワイヤレスログ転送機能のMac用ベータアプリです。macOS 27以降に対応します。Macが解析ログを取得して保持し、iPhone/iPadでMochiLogを開いたときにローカルネットワークで暗号化して転送します。解析と記録はiPhone/iPad側で行います。

## 利用手順

1. 署名済みDMGを開き、`MochiLog Mac.app`をApplicationsへコピーします。Python、Xcode、Homebrewの追加インストールは不要です。
2. iPhone/iPadとMacを同じWi-Fiに接続し、Bluetoothをオンにします。初回OSペアリング時のみiPhone/iPadのデベロッパモードをオンにし、Macアプリの案内に従って6桁コードを入力します。完了後はオフに戻せます。
3. Macアプリで端末を選んでMochiLogペアリングを作成し、iPhone/iPadのMochiLogの「設定 → 高度な設定 → Mac連携」でQRコードを読み取ります。QRコードには秘密鍵が含まれるため共有しないでください。
4. Macアプリを起動したままにすると定期的にログを収集します。Macは明らかに対象外のsessionファイル、極端に短いファイル、電池ログの必須キーがないファイルを除外します。ペアリング済みApple WatchのログはiPhone内の代理端末領域から取得し、ログのOS表記でiPhone/Watchを区別します。同日・同名のログも取得元ごとに保持します。iPhone/iPadのMochiLogを開くと転送と取り込みが始まり、値の解析・記録は端末側で行います。

ベータ版です。解析ログの収集は端末のロック解除中にのみ可能です。iOS 16の端末はMochiLog本体を引き続き使えますが、このMac連携機能の対象外です。

Mac内の転送待ちログ、ペアリング情報、診断情報の扱いは[プライバシーポリシー](https://mochilog.ryuya-dev.net/privacy)に、利用条件は[利用規約](https://mochilog.ryuya-dev.net/terms)に記載しています。アプリのサポート欄から両文書を開けます。サポートメールには、送信操作をした場合に限り端末・Macの診断情報を添付します。

## GitHub Actionsで署名済みDMGを作る

Actionsの「Signed beta DMG」を手動実行すると、macOS 27/Xcode 27のランナーでビルドし、Developer ID署名、公証、ステープル、Gatekeeper検証を行います。完了後、実行結果の「Artifacts」から`MochiLog-Mac-Beta-notarized-<実行番号>`をダウンロードすると、DMGとSHA-256チェックサムを取得できます。成果物の保存期間は90日です。このワークフローはGitHub Releaseを作成しません。リポジトリのActions secretsに`MOCHILOG_CERTIFICATE_P12_BASE64`（空パスワードのDeveloper ID Application p12をbase64化した値）、`MOCHILOG_NOTARY_KEY_BASE64`（App Store Connect APIキーp8のbase64）、`MOCHILOG_NOTARY_KEY_ID`、`MOCHILOG_NOTARY_ISSUER_ID`を設定してください。証明書やAPIキーの実体はリポジトリへコミットしません。

## ベータ版の更新と公開

開発版のバージョンは`0.x.y`とし、正式公開時に`1.0.0`へ上げます。アプリにはSparkleを組み込み、GitHub Releasesに公開した署名済み・公証済みDMGから自動更新します。更新フィードの`appcast.xml`とDMGはEdDSAで署名し、アプリ側で署名を検証します。更新の自動確認・ダウンロード・終了時のインストールを既定で有効にしています。OSの権限が必要な場合はユーザーの操作が必要です。

リリース前にソースをコミット・プッシュし、`fastlane mac beta_dmg`と`fastlane mac notarize_beta`を実行します。秘密鍵をリポジトリ外へ置き、`MOCHILOG_SPARKLE_KEY_PATH=/absolute/path/to/key scripts/publish-beta-release.sh`でGitHub Releaseの作成、DMGのアップロード、署名済み更新フィードの公開・検証を行います。次のリリースでは`MARKETING_VERSION`と`CURRENT_PROJECT_VERSION`を両方上げてください。署名・公証済みの実DMGを公開し、古いファイルは上書きしません。GitHub Actionsの`Signed beta DMG`は署名・公証済み成果物の作成までを行い、Release公開には同じスクリプトを使います。

OSの言語設定に合わせて、日本語・英語・簡体字中国語・繁体字中国語・韓国語・スペイン語・フランス語・ドイツ語の案内と診断画面を表示します。

## ビルド

開発者はXcode 27、XcodeGen、fastlane、Python 3とDeveloper ID Application証明書を用意し、`fastlane mac beta_dmg`を実行します。完成した配布物は`Build/MochiLog-Mac-Beta.dmg`です。使用者側にはこれらの依存は不要です。公証用のkeychain profileがある場合は`MOCHILOG_NOTARY_PROFILE=<profile> fastlane mac notarize_beta`で**アプリ本体とDMGの両方**を公証・stapleします。APIキーを使う場合は`MOCHILOG_NOTARY_KEY_PATH`、`MOCHILOG_NOTARY_KEY_ID`、`MOCHILOG_NOTARY_ISSUER_ID`を環境変数で渡します。認証情報はリポジトリへ保存しません。

`pymobiledevice3`およびビルド時依存のバージョンは`requirements-build.txt`で固定しています。ライセンスはMacアプリの「ライセンスとお知らせ」画面、または`LICENSE`と`THIRD_PARTY.md`を参照してください。
