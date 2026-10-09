# MochiLog Mac

MochiLog Mac は、iPhone・iPad のバッテリー解析ログを Mac で収集し、端末で MochiLog を開いたときに暗号化して渡すベータアプリです。Apple Watch のログがペアリング先の iPhone に保存されていれば、それも対象です。解析と記録は端末側で行います。PC 連携を設定しなくても、スマホ版の手動読み込みは使えます。

macOS 27 と iOS/iPadOS 27 向けです。[GitHub Releases](https://github.com/MochiLog/MochiLog-Mac/releases)から DMG を入手し、`MochiLog Mac.app` を「アプリケーション」にコピーしてください。利用者が Xcode、Python、Homebrew を入れる必要はありません。

初回は端末のロックを解除し、Mac アプリの「端末」で接続を設定します。必要に応じて一度 USB 接続して「このコンピュータを信頼」を許可します。無線接続を確認したら Mac に表示される QR を、端末の「MochiLog → 設定 → 自動ログ収集 → PC 連携」で読み取り、確認コードを入力します。以後は Mac に収集済みのログを、端末で MochiLog を開くと受信できます。

詳しい画面ごとの手順、日々の使い方、トラブル対応は[日本語・英語の利用ガイド](docs/USER_GUIDE.md)をご覧ください。開発・ビルド・署名・転送プロトコルの情報は[開発者向け文書](docs/DEVELOPMENT.md)にあります。

## 現在のバッテリー値（ベータ）

スマホの高度な設定でオンにすると、新しいタブで現在の充放電回数・容量を確認できます。履歴には保存しません。PCの「現在のバッテリー」画面にも端末ごとに表示します。詳しくは利用ガイドをご覧ください。

---

MochiLog Mac is a beta companion that collects iPhone and iPad battery analytics files and transfers them over an encrypted connection when you open MochiLog on the device. It also handles eligible Apple Watch files stored on a paired iPhone. Parsing and record creation happen on the mobile device. The mobile app works without Mac pairing.

It supports macOS 27 and iOS/iPadOS 27. Download a DMG from [GitHub Releases](https://github.com/MochiLog/MochiLog-Mac/releases) and copy `MochiLog Mac.app` to Applications. You do not need Xcode, Python, or Homebrew. For initial setup, unlock the device and follow **Devices** in the Mac app. If prompted, connect by USB once and approve **Trust This Computer**. When wireless access is confirmed, scan the Mac's QR code in **MochiLog → Settings → Automatic Log Collection → PC Transfer** and enter the confirmation code.

See the [Japanese and English user guide](docs/USER_GUIDE.md) for detailed setup, everyday use, and troubleshooting. Build, signing, and protocol details are in the [developer notes](docs/DEVELOPMENT.md).

Current battery values are also available in the computer’s Live Battery screen and an optional mobile tab, disabled by default. These values are not saved as history. See the user guide for details.

同じPCとペアリングした複数のiPhone・iPadでは、同じApple Accountで双方のiCloud同期が有効と確認できる場合に限り、他の端末のログも暗号化して受信できます。未確認・同期オフ・別アカウントなら共有しません。共有元のアプリをしばらく開いていない場合は再確認まで保留します。詳しくは[利用ガイド](docs/USER_GUIDE.md)を参照してください。

Devices paired with the same computer can receive each other’s logs when both have confirmed iCloud sync enabled on the same Apple Account. Disabled sync, different accounts or unconfirmed permissions prevent sharing. If the source app has not been opened for a while, sharing waits for renewed confirmation. See the [user guide](docs/USER_GUIDE.md).

自動更新確認は初期状態でオフです。初回の選択画面または設定でオンにできます。同じApple AccountのiCloud同期を双方で有効にしている場合は、現在のバッテリー値も他の端末へ共有します。スマホの実験的な端末内取得はPC連携と別々に切り替えられ、初期状態でオフです。[使い方と条件](https://github.com/MochiLog/MochiLog/blob/experiment/mac-log-transfer/docs/automatic-log-collection.md)をご確認ください。

Automatic update checks are off by default and can be enabled in the initial prompt or settings. Current battery values can also be shared between devices with confirmed iCloud sync on the same Apple Account. Experimental on-device collection in the mobile app is independently configurable and off by default. See the [guide and requirements](https://github.com/MochiLog/MochiLog/blob/experiment/mac-log-transfer/docs/automatic-log-collection.md).

スマホ版[TestFlight 4.0.0（1044）](https://testflight.apple.com/join/vnHYsRgN)では、[idevice_pairからのペアリングファイル直接インストール](https://github.com/MochiLog/MochiLog#400ベータの対応)にも対応しています。MochiLog対応版のツールが必要です。公式ツールへのアプリ登録は[PR #84](https://github.com/jkcoxson/idevice_pair/pull/84)で提案中です。PC連携は引き続きiOS/iPadOS 27以降が対象で、端末内取得は17以降、端末内の初回ペアリングは27以降・Developer Mode必須です。アプリ内の開始前の案内で、設定経路・再起動・再起動後の承認を確認してください。

Mobile TestFlight beta 4.0.0 (1044) supports direct pairing-file installation from a MochiLog-compatible idevice_pair build. Official tool registration is proposed in [PR #84](https://github.com/jkcoxson/idevice_pair/pull/84). PC transfer still targets iOS/iPadOS 27+; on-device collection targets 17+, with device-only initial pairing requiring 27+ and Developer Mode. Follow the in-app prerequisite card for settings, restart and approval after restart. See the [mobile beta announcement](https://github.com/MochiLog/MochiLog#400ベータの対応).
