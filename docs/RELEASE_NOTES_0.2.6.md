# MochiLog Mac 0.2.6 Beta

## 日本語

MochiLog Macは、iOS/iPadOS 27の解析ログをiPhone・iPad版MochiLogへ渡すためのmacOS 27向けベータ版です。Macがログを収集・一時保存し、解析と記録はiPhone・iPad側で行います。配布するDMGには必要な収集ツールが同梱されており、利用者がXcodeやPythonを別途インストールする必要はありません。アプリ本体とDMGはDeveloper IDで署名・公証しています。

- 初回はMacと端末のOSペアリングを確認し、MacアプリのQRコードをiPhone・iPad版MochiLogで読み取って連携します。OSペアリングがまだない場合は、端末をロック解除してUSBで一度「このコンピュータを信頼」してください。既に無線ペアリング済みなら再設定は不要です。
- Macはロック解除中のiPhone・iPadから対象の解析ログを収集します。ペアリング済みApple WatchのログがiPhone側に保存されている場合は、それらも対象です。明らかに対象外のセッションファイルや短いファイルを除外します。
- MochiLogを開くとMacに保存されたログを暗号化して受信します。受信確認後にMacのキューから削除し、再接続・再送時には重複記録を防ぎます。iPhoneとiPadの両方でローカルWi-FiおよびTailscale経由の転送を実機確認しました。速度制限中のモバイル回線でも17.85MBのファイルを最後まで転送し、確認応答を受け取れています。
- 連携状態、収集の進捗、デバッグログ、サポート用の診断情報を確認できます。メニューバー表示、Dock表示の切り替え、ログイン時の起動、GitHub Release経由の更新確認に対応します。

**ベータ版の条件:** Macが端末内の新しい解析ログを収集するには、端末のロック解除とAppleの診断サービスが利用できるローカル無線接続が必要です。Tailscaleのモバイル通信経由では、Macが既に収集したログの転送はできますが、端末内の新しい解析ログの収集はできません。収集や初回ペアリングは環境によってタイムアウトする場合があります。詳細はアプリのMac連携サポートから診断情報とともに報告できます。

## English

MochiLog Mac is a macOS 27 beta companion for delivering iOS/iPadOS 27 analytics logs to MochiLog on iPhone and iPad. The Mac collects and temporarily queues files; the iPhone or iPad app parses and records them. The signed and notarized DMG includes the collector and its dependencies, so users do not need to install Xcode or Python.

- Check the device's OS pairing, then scan the QR code shown by MochiLog Mac in the iPhone or iPad app. If the Mac has not been trusted before, unlock the device, connect it by USB once, and approve “Trust This Computer.” Existing wireless pairing can be reused.
- Collect eligible analytics logs from an unlocked iPhone or iPad, including paired Apple Watch logs stored on the iPhone when available. Session files and implausibly short files are excluded.
- When MochiLog opens, it receives queued files through an encrypted connection. Files leave the Mac queue only after acknowledgement, and retries avoid duplicate records. Transfers over local Wi-Fi and Tailscale were verified on both iPhone and iPad. A 17.85 MB file completed over a throttled cellular connection and was acknowledged.
- Inspect pairing status, collection progress, debug events, and support diagnostics. The app supports a menu bar item, optional Dock visibility, launch at login, and update checks through GitHub Releases.

**Beta requirements and limits:** Collecting new on-device analytics logs requires an unlocked device and a local wireless connection that exposes Apple's diagnostic service. Tailscale over cellular can transfer files already collected by the Mac, but cannot collect new system analytics files from the device. Collection and initial pairing may time out on some networks. The Mac transfer support screen can attach diagnostics to a report.
