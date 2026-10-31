# MochiLog Mac

**Macにログを集めて、iPhone・iPadでバッテリーの変化を記録。**

MochiLog Macは、iPhone・iPadのバッテリー解析ログを収集し、スマホ版MochiLogへ暗号化して転送するコンパニオンアプリです。Apple Watchのログがペアリング先のiPhoneに保存されている場合は、それも収集できます。

[最新版をダウンロード](https://github.com/MochiLog/MochiLog-Mac/releases/latest) · [利用ガイド](docs/USER_GUIDE.md) · [スマホ版MochiLog](https://github.com/MochiLog/MochiLog) · [公式サイト](https://mochilog.ryuya-dev.net/)

## 必要なもの

- macOS 27以降のMac
- iOS / iPadOS 27以降の端末と、スマホ版MochiLog
- 初回の信頼設定が必要な場合は、データ通信に対応したUSBケーブル

DMGを入れるだけで利用できます。Python、Xcode、Homebrewを別途インストールする必要はありません。

## はじめ方

1. 最新のDMGを開き、`MochiLog Mac.app`を「アプリケーション」にコピーして起動します。
2. 端末をロック解除し、Macと同じWi-Fiに接続します。Wi-FiとBluetoothをオンにしてください。
3. Macアプリの「端末」で設定するiPhone・iPadを選び、表示された案内に従って信頼設定と無線接続を確認します。未設定の場合は、初回だけUSB接続して端末の「このコンピュータを信頼」を許可します。
4. Macに表示されたQRを、端末の「MochiLog → 設定 → 自動ログ収集 → PC連携」で読み取り、確認コードを入力します。
5. Macアプリを起動したままにします。端末でMochiLogを開くと、収集済みログを受信して解析・記録します。

すでに無線ペアリング済みの端末は、アプリの案内に従って先へ進めます。詳しい初回設定と画面ごとの操作は[利用ガイド](docs/USER_GUIDE.md)をご確認ください。

## 日々の使い方

- **ログの収集：** 端末のロック解除中に収集します。必要なときは「今すぐログを収集」を使えます。
- **ログの受信：** スマホ版を開いて受信します。手動で「今すぐ受信」を押すこともできます。
- **現在のバッテリー：** Macの専用画面や、スマホ版で有効にした現在値タブから確認できます。現在値は履歴には保存しません。
- **電池ログの管理：** 転送待ち・送信済みのファイルを確認し、書き出しや再送ができます。送信後の保管期間と容量上限も設定できます。
- **常駐と更新：** ログイン時の起動、メニューバーでの常駐、自動更新確認を設定できます。初期状態ではウィンドウを閉じてもメニューバーに残ります。

外出先から収集済みログを受け取る場合は、任意のTailscale接続とスマホ側のモバイル通信許可を利用できます。新しいログの収集には、ローカルの無線接続と端末のロック解除が必要です。

## 困ったときは

[利用ガイドのトラブル対応](docs/USER_GUIDE.md)をご確認ください。アプリ内のサポート画面から、発生日を指定して診断情報を添えた問い合わせも作成できます。

[サポート](https://mochilog.ryuya-dev.net/support?lang=ja) · [プライバシーポリシー](https://mochilog.ryuya-dev.net/privacy?lang=ja) · [利用規約](https://mochilog.ryuya-dev.net/terms?lang=ja)

## English

MochiLog Mac collects iPhone and iPad battery analytics files and transfers them over an encrypted connection to the mobile MochiLog app. Eligible Apple Watch files stored on the paired iPhone are included. The mobile app analyzes the files and saves the records.

You need macOS 27+ and an iPhone or iPad running iOS/iPadOS 27+. Download the latest [DMG](https://github.com/MochiLog/MochiLog-Mac/releases/latest), copy the app to Applications, and follow **Devices** to set up trust and wireless access. Scan the pairing QR in **MochiLog → Settings → Automatic Log Collection → PC Transfer**, then enter the confirmation code. You do not need to install Python, Xcode or Homebrew.

Leave the Mac app running and unlock the device for collection. Open the mobile app to receive collected logs. Use the Battery Logs screen to manage stored files, Live Battery to see current readings, and settings to configure login launch, menu bar behavior and update checks. See the [Japanese and English user guide](docs/USER_GUIDE.md) for full setup and troubleshooting.

---

[開発者向け文書 / Developer documentation](docs/DEVELOPMENT.md) · [ライセンス / License](LICENSE)
