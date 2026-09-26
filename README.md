# MochiLog Mac

MochiLogのiOS/iPadOS 27向けワイヤレスログ転送機能のMac用ベータアプリです。macOS 27以降に対応します。Macが解析ログを取得して保持し、iPhone/iPadでMochiLogを開いたときにローカルネットワークで暗号化して転送します。解析と記録はiPhone/iPad側で行います。

## 利用手順

1. 署名済みDMGを開き、`MochiLog Mac.app`をApplicationsへコピーします。Python、Xcode、Homebrewの追加インストールは不要です。
2. iPhone/iPadとMacを同じWi-Fiに接続し、Bluetoothをオンにします。すでにOSペアリング済みならMacアプリで端末を選び、無線接続の確認後に次へ進めます。未ペアリングなら、無線で初回だけデベロッパモードを使い6桁コードを入力する方法、またはUSBで「このコンピュータを信頼」を許可して「USBで設定」を押す方法を選べます。USB設定後はケーブルを外し、Macアプリで無線の診断ログ接続を確認します。確認できない場合は無線ペアリングを試してください。
3. Macアプリで端末を選んでMochiLogペアリングを作成し、iPhone/iPadのMochiLogの「設定 → 高度な設定 → Mac連携」でQRコードを読み取ります。Macに表示された6桁の確認コードを端末へ入力してください。QRには一時公開鍵や端末情報が含まれますが、秘密鍵と確認コードは含まれません。確認コード自体も通信せず、セッションIDと鍵交換で得た共有鍵を使ったHMACで照合します。QRと確認コードは3分で失効するため、ペアリング時だけ表示してください。
4. Macアプリを起動したままにすると定期的にログを収集します。Macは明らかに対象外のsessionファイル、極端に短いファイル、電池ログの必須キーがないファイルを除外します。ペアリング済みApple WatchのログはiPhone内の代理端末領域から取得し、ログのOS表記でiPhone/Watchを区別します。同日・同名のログも取得元ごとに保持します。iPhone/iPadのMochiLogを開くと転送と取り込みが始まり、値の解析・記録は端末側で行います。

ベータ版です。解析ログの収集は端末のロック解除中にのみ可能です。iOS 16の端末はMochiLog本体を引き続き使えますが、このMac連携機能の対象外です。

TailscaleをMacとiPhone/iPadの両方で同じtailnetに接続している場合、初回のQRペアリングでMacのTailscale IPも保存します。通常は同じWi-Fi上のMacへ接続し、見つからない場合は保存したIPへ直接接続します。BonjourのマルチキャストをTailscaleへ流す必要はありません。Tailscaleは任意で、利用しない場合は同じWi-Fiで使えます。別ネットワークからの接続には、両端末のTailscale接続とtailnetでMacのTCPポート`54557`へのアクセス許可が必要です。Mac側のTailscale IPが変わった場合は、同じWi-Fiで一度接続して更新するか、QRでペアリングし直してください。

後からOSペアリングが切れた場合も、MochiLogの端末登録と転送待ちログは保持します。端末のロック解除とWi-Fiを確認して再検索し、接続できなければOSペアリングだけやり直します。USBのみで初回設定した未ペアリングのiPadでも、ケーブルを外してWi-Fi経由で解析ログを取得できたことを確認しています。端末やネットワーク条件による差があるため、MochiLogのQRはMacが実際に無線接続できた場合だけ表示します。

初回も無線でデベロッパモードを使わない設定についての調査結果と、両方式の検証範囲は[初回ペアリングの制約](docs/FIRST_PAIRING.md)に記録しています。

Mac内の転送待ちログ、ペアリング情報、診断情報の扱いは[プライバシーポリシー](https://mochilog.ryuya-dev.net/privacy)に、利用条件は[利用規約](https://mochilog.ryuya-dev.net/terms)に記載しています。アプリのサポート欄から両文書を開けます。サポートメールには、送信操作をした場合に限り端末・Macの診断情報を添付します。

## GitHub Actionsで署名済みDMGを作る

転送プロトコルの認証・応答・iPhone/Watch別キュー・受信確認・再送防止は `bash scripts/test-transfer-protocol.sh` で自動検証できます。一時ディレクトリだけを使い、実機の記録やMacの転送キューは変更しません。

Actionsの「Signed beta DMG」を手動実行すると、macOS 27/Xcode 27のランナーでビルドし、Developer ID署名、公証、ステープル、Gatekeeper検証を行います。完了後、実行結果の「Artifacts」から`MochiLog-Mac-Beta-notarized-<実行番号>`をダウンロードすると、DMGとSHA-256チェックサムを取得できます。成果物の保存期間は90日です。このワークフローはGitHub Releaseを作成しません。リポジトリのActions secretsに`MOCHILOG_CERTIFICATE_P12_BASE64`（空パスワードのDeveloper ID Application p12をbase64化した値）、`MOCHILOG_NOTARY_KEY_BASE64`（App Store Connect APIキーp8のbase64）、`MOCHILOG_NOTARY_KEY_ID`、`MOCHILOG_NOTARY_ISSUER_ID`を設定してください。証明書やAPIキーの実体はリポジトリへコミットしません。

## ベータ版の更新と公開

開発版のバージョンは`0.x.y`とし、正式公開時に`1.0.0`へ上げます。アプリにはSparkleを組み込み、GitHub Releasesに公開した署名済み・公証済みDMGから自動更新します。更新フィードの`appcast.xml`とDMGはEdDSAで署名し、アプリ側で署名を検証します。更新の自動確認・ダウンロード・終了時のインストールを既定で有効にしています。OSの権限が必要な場合はユーザーの操作が必要です。

リリース前にソースをコミット・プッシュし、`fastlane mac beta_dmg`と`fastlane mac notarize_beta`を実行します。秘密鍵をリポジトリ外へ置き、`MOCHILOG_SPARKLE_KEY_PATH=/absolute/path/to/key scripts/publish-beta-release.sh`でGitHub Releaseの作成、DMGのアップロード、署名済み更新フィードの公開・検証を行います。次のリリースでは`MARKETING_VERSION`と`CURRENT_PROJECT_VERSION`を両方上げてください。署名・公証済みの実DMGを公開し、古いファイルは上書きしません。GitHub Actionsの`Signed beta DMG`は署名・公証済み成果物の作成までを行い、Release公開には同じスクリプトを使います。

OSの言語設定に合わせて、日本語・英語・簡体字中国語・繁体字中国語・韓国語・スペイン語・フランス語・ドイツ語の案内と診断画面を表示します。

## ビルド

開発者はXcode 27、XcodeGen、fastlane、Python 3とDeveloper ID Application証明書を用意し、`fastlane mac beta_dmg`を実行します。完成した配布物は`Build/MochiLog-Mac-Beta.dmg`です。使用者側にはこれらの依存は不要です。公証用のkeychain profileがある場合は`MOCHILOG_NOTARY_PROFILE=<profile> fastlane mac notarize_beta`で**アプリ本体とDMGの両方**を公証・stapleします。APIキーを使う場合は`MOCHILOG_NOTARY_KEY_PATH`、`MOCHILOG_NOTARY_KEY_ID`、`MOCHILOG_NOTARY_ISSUER_ID`を環境変数で渡します。認証情報はリポジトリへ保存しません。

`pymobiledevice3`およびビルド時依存のバージョンは`requirements-build.txt`で固定しています。ライセンスはMacアプリの「ライセンスとお知らせ」画面、または`LICENSE`と`THIRD_PARTY.md`を参照してください。
