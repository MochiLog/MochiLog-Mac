# MochiLog Mac ベータ版 利用ガイド / User guide

## 日本語

### できること

MochiLog Mac は、iPhone・iPad の解析ログを Mac に一時保管し、端末で MochiLog を開いたときに暗号化して渡します。Apple Watch のログがペアリング先の iPhone に保存されていれば、それも対象です。解析と記録は iPhone・iPad 側で行います。Mac 連携を設定しなくても、スマホ版の手動読み込みや記録は使えます。

### 準備と初回設定

1. [GitHub Releases の最新ベータ版 DMG](https://github.com/MochiLog/MochiLog-Mac/releases)を開き、`MochiLog Mac.app` を「アプリケーション」にコピーして起動します。macOS 27 以降が必要です。Xcode、Python、Homebrew の準備は不要です。
2. iPhone・iPad と Mac の Wi-Fi と Bluetooth をオンにします。端末のロックを解除し、できれば同じ Wi-Fi に接続してください。
3. Mac アプリの「端末」で設定する端末を選びます。OS のペアリングがまだなら、画面の案内に従って初回だけ USB ケーブルで接続し、端末に表示される「このコンピュータを信頼」を許可します。すでに無線ペアリング済みなら、この操作は不要です。無線での初回設定が表示される環境では、画面の6桁コードでも設定できます。
4. Mac アプリで無線接続の確認後、「MochiLog ペアリングを作成」を押します。端末の MochiLog で「設定 → 高度な設定 → Mac 連携」を開き、QR コードを読み取って Mac に表示された確認コードを入力します。QR は短時間で失効します。
5. Mac アプリを起動したままにします。Mac がログを収集し、iPhone・iPad で MochiLog を開くと受信と記録が始まります。必要なら双方の「今すぐ」の操作で再試行できます。

### 日々の使い方

新しい解析ログを Mac が収集できるのは、端末のロックが解除されていて無線の診断接続が使えるときだけです。収集済みのログは Mac に残るので、その場でスマホ版を開く必要はありません。ログが届かないときは、まず端末で MochiLog を開いて「Mac 連携」の接続状態を確認してください。必要な当日分が揃うと不要な自動再走査を休止します。手動収集・受信は引き続き利用できます。

初期設定では Mac アプリのウィンドウを×で閉じてもメニューバーに残り、収集と転送を続けます。メニューバーのアイコンからウィンドウを再表示できます。完全に終了したいときはメニューバーの「終了」を選びます。「設定 → ウィンドウを閉じたとき」で、×を押すとアプリを終了する動作にも変更できます。

Mac の「電池ログ」では未転送・送信済みの生ログを確認、書き出し、再送できます。初期設定では受信確認後に送信済みログを削除します。「送信後も保管」を選ぶと保管期間と容量上限を設定できます。未転送ログは自動整理から保護されます。

Tailscale は任意です。同じ Wi-Fi の外からは、双方で Tailscale を接続し、端末側でモバイル通信の転送を許可すると、Mac に**収集済み**のログを受け取れます。外出先のモバイル通信だけで端末内の新しい解析ログを Mac が収集することはできません。

### 困ったときは

- **ログが生成されない:** 端末の「設定 → プライバシーとセキュリティ → 解析と改善」で解析の共有を確認します。OS アップデート後も確認してください。設定直後は次のログ生成まで時間がかかります。
- **端末が見つからない:** 端末のロック、Wi-Fi、Bluetooth、Mac のスリープ状態を確認し、「端末」で再検索します。OS の信頼設定が切れた場合は、Mac アプリの案内に従って設定し直してください。
- **収集済みだが記録が増えない:** 該当端末で MochiLog を開き、「Mac 連携」で接続と処理結果を確認します。すでに読み込んだログは重複防止のため再登録されません。
- **接続が繰り返し失敗する:** Mac と端末の「Mac 連携」にある日付別デバッグログを確認してください。サポート画面では発生日を指定して関連ログを添付できます。生の解析ログやペアリング鍵は自動添付されません。

この機能はベータ版です。問題の解決には時間がかかり、個別に返信できない場合があります。[プライバシーポリシー](https://mochilog.ryuya-dev.net/privacy)と[利用規約](https://mochilog.ryuya-dev.net/terms)も参照してください。

## English

### What it does

MochiLog Mac collects Apple analytics files from an iPhone or iPad, temporarily queues them, and sends them over an encrypted connection when you open MochiLog on that device. Eligible Apple Watch files stored on its paired iPhone are included. Parsing and record creation happen on the iPhone or iPad. The mobile app also works without computer pairing.

### Set up

1. Open the latest beta DMG from [GitHub Releases](https://github.com/MochiLog/MochiLog-Mac/releases), copy `MochiLog Mac.app` to Applications, and launch it. macOS 27 or later is required. You do not need Xcode, Python, or Homebrew.
2. Turn on Wi-Fi and Bluetooth on the computer and device. Unlock the device and, preferably, connect both to the same Wi-Fi network.
3. Select the device on the Mac app's **Devices** page. If OS pairing is new, connect a USB data cable once and approve **Trust This Computer** on the device. Skip this if wireless OS pairing already works. Where wireless first-time setup is offered, you can use its six-digit code instead.
4. Once the Mac confirms wireless access, create a MochiLog pairing. On the device, open **MochiLog → Settings → Advanced Settings → Mac Transfer**, scan the QR code, and enter the confirmation code shown on the Mac. The QR expires shortly.
5. Leave MochiLog Mac running. It collects files when the unlocked device is reachable. Open the mobile app to receive and record them. Use **Collect Now** or **Receive Now** to retry manually.

### Everyday use and help

The device must be unlocked and locally reachable while the Mac collects new analytics files. Queued files remain on the Mac until the mobile app can receive them. Once the required daily files are present, unnecessary automatic rescans pause; manual actions remain available. The **Battery Logs** page lists pending and delivered raw files and supports export and resend. Delivered files are deleted after acknowledgement by default, or you can enable retention with configurable limits. Pending files are protected from automatic cleanup.

By default, closing the Mac app's window keeps it running in the menu bar so collection and transfers continue. Use the menu bar icon to reopen the window, or choose **Quit** there to stop the app. You can change this under **Settings → When closing the window** so closing the window quits the app instead.

Tailscale is optional. If both devices use it and mobile transfer is enabled, you can receive files **already collected** by the Mac while away. Cellular plus Tailscale cannot collect new system analytics from the device.

If logs do not appear, check **Settings → Privacy & Security → Analytics & Improvements** on the iPhone or iPad, especially after an OS update. Check that the device is unlocked, Wi-Fi and Bluetooth are on, and the Mac is awake. Open MochiLog on the device to complete receipt; duplicates are not recorded twice. For persistent failures, review the dated debug logs on both devices and use the support screen to attach logs for the incident date. Raw analytics files and pairing keys are not attached automatically.

This is a beta. Fixes may take time and individual replies may not always be possible. See the [privacy policy](https://mochilog.ryuya-dev.net/privacy) and [terms](https://mochilog.ryuya-dev.net/terms).

## 現在のバッテリー値（ベータ）

ペアリングしたiPhone・iPadの充放電回数、設計容量、最大容量などを、PCの概要画面で端末ごとに確認できます。スマホでも使う場合は **設定 → 高度な設定 → 現在のバッテリー** をオンにしてください。初期状態はオフです。既存のPCペアリングを使うため、この機能のための再ペアリングは不要です。

アプリを開いている間は定期的に取得し、変化した値だけを暗号化して送ります。最終取得日時を表示し、取得できない項目は空欄として扱います。接続できない場合は最後の値を過去の値として表示します。**今すぐ受信／送信**で手動更新もできます。スマホからのPC更新要求は、PCの取得完了後に次の受信で反映されます。

この表示は日次の解析ログとは別の現在値です。履歴・バッテリー記録・iCloudには保存しません。アプリ終了後は値を保持しません。診断項目の意味や取得可否はOS・機種で異なるため、日次ログと一致する保証はありません。ロック中に取得できた場合もありますが、長時間のロックや接続条件で取得できないことがあります。Apple Watchの現在値を測る機能ではありません。スマホ単体の手動ログ読み込みはこれまでどおり使えます。

スマホはMochiLog 4.0.0の新しいベータ、PCはMochiLog Mac 0.2.14／MochiLog Windows 0.1.11以降に更新してください。モバイル通信ではPC連携のモバイル通信設定とTailscaleによる接続が必要です。

## Current battery values (beta)

View cycle count, design capacity and other current capacity fields for each paired iPhone or iPad on the computer dashboard. On mobile, enable **Settings → Advanced Settings → Live Battery** to show the new tab. It is **off by default**. It uses your existing computer pairing; no new pairing is required.

Values refresh periodically while the app is open. Only changed values are sent, using encrypted transfer. The display includes the last acquisition time; unavailable fields remain empty, and a failed refresh leaves the previous values marked as outdated. Use **Receive Now / Send Now** for a manual update. A mobile request to refresh the computer appears on a subsequent receive after acquisition completes.

These are current diagnostic values, separate from daily Analytics files. They are not saved as history, battery records or iCloud data, and are discarded when the app exits. Available fields and their meaning depend on the device and OS; they may differ from daily Analytics values. A locked-device query has succeeded in testing, but long locks and connection conditions can prevent acquisition. This feature does not measure live Apple Watch battery values. Manual log import on mobile remains available without a computer.

Use the new MochiLog 4.0.0 beta with MochiLog Mac 0.2.14 or MochiLog Windows 0.1.11 or later. Cellular access requires the companion cellular setting and connectivity through Tailscale.

「APIの全項目」を展開すると、APIが返す製造情報・状態フラグ・バッテリー識別情報なども確認できます。元の項目名・値を表示し、単位は推測しません。これらもメモリ内だけで扱い、履歴・サポートログには保存しません。TailscaleとPC連携のモバイル通信許可を使って外出先からも受信できます。PCから新しい値を取得するには端末の診断サービスに接続できる必要があり、VPNの接続だけで取得を保証するものではありません。

Expand **All API fields** to view manufacturing metadata, flags, battery identifiers and other returned fields. Original names and values are preserved without guessing units; fields remain in memory and are not saved to history or support logs. Existing Tailscale routes and the PC Link cellular permission also allow receiving outside the local network. Fresh acquisition additionally requires a reachable device diagnostics service; VPN connectivity alone does not guarantee acquisition.
