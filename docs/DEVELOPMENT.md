# MochiLog Mac — 開発・運用メモ

利用者向けの導入手順と困ったときの案内は[日本語・英語の利用ガイド](USER_GUIDE.md)を参照してください。

MochiLogのiOS/iPadOS 27向けワイヤレスログ転送機能のMac用ベータアプリです。macOS 27以降に対応します。Macが解析ログを取得して保持し、iPhone/iPadでMochiLogを開いたときにローカルネットワークで暗号化して転送します。解析と記録はiPhone/iPad側で行います。

## Mac連携でできること

Macアプリを起動して端末をペアリングすると、端末のロック解除中にバッテリー解析ログをWi-Fiで収集し、転送待ちとして保管します。iPhone/iPadでMochiLogを開くと、保管したログを暗号化して受け取り、アプリ側で解析・記録します。ペアリング済みApple Watchのログも、iPhone内にあるものは収集対象です。iCloud同期はこれとは別の任意設定です。

Mac連携を設定しなくても、iPhone/iPadのMochiLogは従来どおり使えます。設定アプリから解析ログを手動で共有し、記録・分析・グラフを利用できます。Mac連携は手動共有の手間を減らすためのベータ機能です。

「電池ログ」画面では、転送待ちと送信済みの生ログを確認し、書き出せます。初期設定ではスマホが受領を確認したログをすぐ削除します。「送信後も保管」を選ぶと送信済みログを最大500MB・1か月（変更可）保存し、選択して手動再送や削除ができます。未受領の転送待ちログは容量・期間による整理と手動削除の対象外です。再送を受け取るにはスマホでMochiLogを開き、必要なら「今すぐ受信」を押してください。Macはログ本文を解析しません。

## 利用手順

1. 署名済みDMGを開き、`MochiLog Mac.app`をApplicationsへコピーします。Python、Xcode、Homebrewの追加インストールは不要です。
2. iPhone/iPadとMacを同じWi-Fiに接続し、Bluetoothをオンにします。すでにOSペアリング済みならMacアプリで端末を選び、無線接続の確認後に次へ進めます。未ペアリングなら、無線で初回だけデベロッパモードを使い6桁コードを入力する方法、またはUSBで「このコンピュータを信頼」を許可して「USBで設定」を押す方法を選べます。USB設定後はケーブルを外し、Macアプリで無線の診断ログ接続を確認します。確認できない場合は無線ペアリングを試してください。
3. Macアプリで端末を選んでMochiLogペアリングを作成し、iPhone/iPadのMochiLogの「設定 → 自動ログ収集 → パソコン連携」でQRコードを読み取ります。Macに表示された6桁の確認コードを端末へ入力してください。QRには一時公開鍵や端末情報が含まれますが、秘密鍵と確認コードは含まれません。確認コード自体も通信せず、セッションIDと鍵交換で得た共有鍵を使ったHMACで照合します。QRと確認コードは3分で失効するため、ペアリング時だけ表示してください。
4. Macアプリを起動したままにすると、起動時とその後5分ごとにログを収集します。収集時に端末がロック中だった場合は、ロック解除後の次の収集で再試行します。Macは明らかに対象外のsessionファイル、極端に短いファイル、電池ログの必須キーがないファイルを除外します。ペアリング済みApple WatchのログはiPhone内の代理端末領域から取得し、ログのOS表記でiPhone/Watchを区別します。同日・同名のログも取得元ごとに保持します。iPhone/iPadのMochiLogを開くと転送と取り込みが始まり、値の解析・記録は端末側で行います。

ベータ版です。解析ログの収集は端末のロック解除中にのみ可能です。iOS 16の端末はMochiLog本体を引き続き使えますが、このMac連携機能の対象外です。

## 困ったときは

- **解析ログがない:** 端末の「設定 → プライバシーとセキュリティ → 解析と改善」で解析の共有を確認してください。OSアップデート後も再確認してください。Macはこのスイッチを直接読めませんが、端末内の解析ログが2日以上新しくなっていない場合はアプリ内で案内します。オンにした直後は次の日次ログの生成まで待つ必要があります。
- **IPが変わった・自動検出できない:** Macアプリの「端末」で連携済みiPhone/iPadのIPv4アドレスを手動指定できます。保存したIPではOSのRemotePairing記録を使って無線診断サービスへ接続します。スマホ側のMac連携画面でもMacのIPを指定できます。自動検出へ戻すときは手動IPを解除してください。
- **Macが収集できない:** 端末をロック解除し、Macをスリープさせず、同じWi-Fiに接続します。Macアプリの「端末」でOSペアリングを確認し、「今すぐログを収集」を試してください。無線診断サービスが空の一覧を返した場合は成功0件と扱わず、別の接続方式を試してからエラーを表示します。Macアプリの動作中は5分ごとに再試行します。
- **収集されたのに記録が増えない:** 該当するiPhone/iPadでMochiLogを開いてください。転送と受信確認の後に端末側で解析します。取り込み済みのログは重複として除外されます。Apple Watchログはペアリング先のiPhoneから届きます。
- **外出先で収集できない:** モバイル回線のTailscaleではMacに収集済みのファイルを転送できますが、端末内の新しい解析ログを取得するにはローカルの無線診断接続が必要です。必要なら設定アプリから手動で共有してください。
- **改善しない:** Macと端末のMac連携画面にあるデバッグログを確認し、サポート画面から診断情報を添えて連絡できます。生の解析ログやペアリング鍵は添付しません。

TailscaleをMacとiPhone/iPadの両方で同じtailnetに接続している場合、初回のQRペアリングでMacのTailscale IPも保存します。通常は同じWi-Fi上のMacへ接続し、見つからない場合は保存したIPへ直接接続します。BonjourのマルチキャストをTailscaleへ流す必要はありません。Tailscaleは任意で、利用しない場合は同じWi-Fiで使えます。別ネットワークからの接続には、両端末のTailscale接続とtailnetでMacのTCPポート`54557`へのアクセス許可が必要です。Mac側のTailscale IPが変わった場合は、同じWi-Fiで一度接続して更新するか、QRでペアリングし直してください。

後からOSペアリングが切れた場合も、MochiLogの端末登録と転送待ちログは保持します。端末のロック解除とWi-Fiを確認して再検索し、接続できなければOSペアリングだけやり直します。USBのみで初回設定した未ペアリングのiPadでも、ケーブルを外してWi-Fi経由で解析ログを取得できたことを確認しています。端末やネットワーク条件による差があるため、MochiLogのQRはMacが実際に無線接続できた場合だけ表示します。

初回も無線でデベロッパモードを使わない設定についての調査結果と、両方式の検証範囲は[初回ペアリングの制約](FIRST_PAIRING.md)に記録しています。

Mac内の転送待ちログ、ペアリング情報、診断情報の扱いは[プライバシーポリシー](https://mochilog.ryuya-dev.net/privacy)に、利用条件は[利用規約](https://mochilog.ryuya-dev.net/terms)に記載しています。アプリのサポート欄から両文書を開けます。サポートメールには、送信操作をした場合に限り端末・Macの診断情報を添付します。

## GitHub Actionsで署名済みDMGを作る

転送プロトコルの認証・応答・iPhone/Watch別キュー・受信確認・再送防止は `bash scripts/test-transfer-protocol.sh` で自動検証できます。一時ディレクトリだけを使い、実機の記録やMacの転送キューは変更しません。

新しいスマホ版は要求本文（受信確認、重複判定、診断情報を含む）をAES-GCMで封印した転送v3を使用します。外側の端末ID・nonce・発行時刻は認証付き追加データにも含まれ、5分を超えた要求は拒否します。使用済みnonceとv3へ移行済みの端末IDはMac上に保存し、再起動後の再送とv2への戻りを拒否します。未認証のLAN接続は同時16件・25秒までです。旧スマホ版は更新前に限り従来のv2で接続でき、画面からTestFlightまたはApp Storeでの更新を案内します。新旧を混在更新してもペアリングは維持します。旧v2要求には発行時刻がないため、完全な時刻検証はv3移行後に適用されます。

対応するモバイル版にはログ本体の送信前にSHA-256を暗号化したofferとして提示します。端末が保存済みなら本体を送らずキューを完了し、ユーザーが指定した手動再送にはこの省略を適用しません。旧モバイル版には従来の転送を続けます。

Actionsの「Signed beta DMG」を手動実行すると、macOS 27/Xcode 27のランナーでビルドし、Developer ID署名、公証、ステープル、Gatekeeper検証を行います。完了後、実行結果の「Artifacts」から`MochiLog-Mac-Beta-notarized-<実行番号>`をダウンロードすると、DMGとSHA-256チェックサムを取得できます。成果物の保存期間は90日です。このワークフローはGitHub Releaseを作成しません。リポジトリのActions secretsに`MOCHILOG_CERTIFICATE_P12_BASE64`（空パスワードのDeveloper ID Application p12をbase64化した値）、`MOCHILOG_NOTARY_KEY_BASE64`（App Store Connect APIキーp8のbase64）、`MOCHILOG_NOTARY_KEY_ID`、`MOCHILOG_NOTARY_ISSUER_ID`を設定してください。証明書やAPIキーの実体はリポジトリへコミットしません。

## ベータ版の更新と公開

開発版のバージョンは`0.x.y`とし、正式公開時に`1.0.0`へ上げます。アプリにはSparkleを組み込み、GitHub Releasesに公開した署名済み・公証済みDMGから自動更新します。更新フィードの`appcast.xml`とDMGはEdDSAで署名し、アプリ側で署名を検証します。更新の自動確認は既定でオフです。初回の確認画面または設定で有効にできます。自動ダウンロードは既定で無効です。OSの権限が必要な場合はユーザーの操作が必要です。

リリース前にソースをコミット・プッシュし、`fastlane mac beta_dmg`と`fastlane mac notarize_beta`を実行します。秘密鍵をリポジトリ外へ置き、`MOCHILOG_SPARKLE_KEY_PATH=/absolute/path/to/key scripts/publish-beta-release.sh`でGitHub Releaseの作成、DMGのアップロード、署名済み更新フィードの公開・検証を行います。次のリリースでは`MARKETING_VERSION`と`CURRENT_PROJECT_VERSION`を両方上げてください。署名・公証済みの実DMGを公開し、古いファイルは上書きしません。GitHub Actionsの`Signed beta DMG`は署名・公証済み成果物の作成までを行い、Release公開には同じスクリプトを使います。

OSの言語設定に合わせて、日本語・英語・簡体字中国語・繁体字中国語・韓国語・スペイン語・フランス語・ドイツ語の案内と診断画面を表示します。

## ビルド

開発者はXcode 27、XcodeGen、fastlane、Python 3.13以降とDeveloper ID Application証明書を用意し、`fastlane mac beta_dmg`を実行します。完成した配布物は`Build/MochiLog-Mac-Beta.dmg`です。使用者側にはこれらの依存は不要です。公証用のkeychain profileがある場合は`MOCHILOG_NOTARY_PROFILE=<profile> fastlane mac notarize_beta`で**アプリ本体とDMGの両方**を公証・stapleします。APIキーを使う場合は`MOCHILOG_NOTARY_KEY_PATH`、`MOCHILOG_NOTARY_KEY_ID`、`MOCHILOG_NOTARY_ISSUER_ID`を環境変数で渡します。認証情報はリポジトリへ保存しません。

`pymobiledevice3`およびビルド時依存のバージョンは`requirements-build.txt`で固定しています。ライセンスはMacアプリの「ライセンスとお知らせ」画面、または`LICENSE`と`THIRD_PARTY.md`を参照してください。

## Current battery protocol (2026-10-07)

The production collector uses pinned pymobiledevice3 11.19.1 DiagnosticsService.get_battery(), not the independent research wire client. BatterySnapshot filters only CycleCount, DesignCapacity, FullChargeCapacity, NominalChargeCapacity, AppleRawMaxCapacity, root CurrentCapacity (percent) and IsCharging. Capacity fields can be nested in BatteryData; nested CurrentCapacity is not treated as percent. Missing, sentinel, invalid or fractional values are not substituted with zero. The revision is SHA-256 of canonical sorted scalar JSON, including the charging boolean, excluding timestamps and identities.

The subprocess emits core scalars and the complete typed battery entry through bounded private stdout pipes. Neither raw IORegistry replies nor filtered values are written to collector logs. LiveBatteryCache is memory-only and excluded from CompanionState, daily archives, support attachments and battery-log storage. Requests use the existing v3 AES-GCM request envelope, expiry, persistent replay protection, authentication, pairing identity and response AAD. Legacy version-1 core responses are unchanged. Opt-in detailsVersion 1 uses a separate SHA-256 over the exact canonical detailsJSON string; unchanged detail revisions omit the string. Each flattened field preserves its path, kind and text value (including 64-bit numbers and Base64 data). Details are limited to 256 KiB and the encrypted frame to 1 MiB. Acquisition output is not persisted. No log acknowledgements, daily completion state, import, iCloud or archive mutation occurs in this branch. Cached values are scoped to the authenticated target device.

Automatic acquisition is serialized with existing collection/pairing. Visible desktop cards or recent authenticated mobile requests trigger polling; failed acquisition backs off. Mobile polling runs only while enabled and foreground, honors cellular/Tailscale settings, and uses existing pairings and discovered/cached routes. Restart discards values. Unsupported older companions require an update, not a pairing reset. A successful current diagnostic query is not proof of locked-state Analytics file acquisition.

Verification: Python whitelist/revision tests; secure transfer protocol tests covering changed/unchanged/stale responses, no persisted values, and v3-only live controls; mobile iPhone/iPad opt-in and rotation tests; an isolated synthetic Mac server → iPad simulator v3 encrypted exchange. Fixtures have synthetic identities and values and never modify real pairings. The full Windows app also builds with zero errors/warnings.

Actionsの`prepare_update_feed`を有効にすると、既存のSparkle署名キーで検証済み更新フィードも成果物に含めます。Release作成やフィード公開は行いません。配布物確認後、同じコミットのDMGをReleaseへ掲載し、検証済みXMLを変更せず公開してください。

Full-field verification: six Python tests, core/full-detail compatibility, changed/unchanged detail responses, 64-bit precision and tamper rejection. Tailscale acquisition was verified from Mac to iPad; this is not evidence of cellular-radio operation until that physical switch is tested. Mac learns only authenticated Tailnet socket peers in memory and tries the existing native path before a remote fallback. The mobile cellular permission remains opt-in.

## コンパイルされた端末通信ヘルパー

ローカルとCIで同じNuitkaビルドを使います。前提条件、実行コマンド、ランタイム依存の切り分けは[COMPILED_COLLECTOR.md](COMPILED_COLLECTOR.md)を参照してください。
