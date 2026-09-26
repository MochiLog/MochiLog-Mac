# 初回の無線ペアリングに関する調査（2026-09-26）

目標は、利用者がUSBケーブルもデベロッパモードも使わずに初回設定し、その後MacがiPhone/iPadの解析ログを自動収集すること。

現在の実装には異なる2種類のペアリングがある。

1. **OSペアリング**: Macの収集ツールが端末の診断ログサービスにアクセスするための信頼設定。初回を無線で行うなら`pymobiledevice3 remote pair-host`を使い、iOS/iPadOS 27の「設定 → デベロッパ → ペアリング済みMac」から端末側で開始する。初回はデベロッパモードが必要。USBで行うなら通常の「このコンピュータを信頼」後に`lockdown remotepairing --pair`を試す。後者のコマンド自体はデベロッパモードを必要としないが、Appleのネイティブ無線経路で使えるかは別途確認が必要。
2. **MochiLogペアリング**: QRコードでMacアプリとiPhone/iPadアプリの暗号化通信を設定する。初回から無線で可能だが、アプリの通信権限だけでOSの解析ログ閲覧権限は得られない。

Appleが案内する通常の「このコンピュータを信頼」およびWi-Fi同期も、初回はケーブルで接続する。`pymobiledevice3`のWi-Fi lockdown経路はUSBで作った信頼レコードを再利用する。`lockdown remotepairing --pair`はツール独自の信頼レコードを作り、Appleのネイティブ経路は未認証のままの場合がある。その場合もWi-Fi lockdownで診断ログを読めれば収集できるよう、Macアプリはネイティブ経路とWi-Fi lockdown経路の両方を実接続で確認する。DeviceDiscoveryUIはアプリ間の無線接続を提供するが、解析ログへのアクセスを許可するAPIではない。

したがって、**初回も無線・デベロッパモードなし・解析ログの自動取得**を同時に満たす、公開された対応方法は現時点で確認できていない。手動共有は無線で可能だが、自動収集にはならない。接続済み端末で読み取れることを、未ペアリング端末への初回アクセスが可能である証拠として扱わない。非公開APIや既存ペアリング鍵の流用を初回設定の代替として案内しない。

実機で確認した範囲: iPhone 17（iOS 27.2）で、無線OSペアリング後にデベロッパモードをオフにした状態をCLIで`false`と確認し、MacからAnalytics名のログ39件を含む474件の一覧を無線で読み取れた。USBで通常の信頼がある状態でも同じログ一覧を読み取れ、デベロッパモードがオフのまま`lockdown remotepairing --pair`が成功して無線用レコードを更新した。通常のWi-Fi lockdown接続はこの実機では切断後に検出できず、収集にはRemotePairing経路を使用する。

追加のiPad Pro（iPadOS 27.2）では、Developer Modeが`false`、AppleのネイティブOSペアリングが`unauthenticated`、`pymobiledevice3`の既存ペアリングファイルなしであることを最初に確認した。USBで「このコンピュータを信頼」後、`lockdown remotepairing --pair`が成功した。ネイティブOSペアリングは引き続き`unauthenticated`だが、`usbmux list --network`にiPadが現れ、**`crash ls --mobdev2`を明示したWi-Fi経路で**`/Retired`の74項目を読み取れた。ケーブルを外した後に`usbmux list --usb`が空、`--network`にはiPadが残り、同じWi-Fi経路で74項目を再度読み取って実ファイル1件（55,511バイト）も取得できた。`lockdown info --mobdev2`でも機種・OSを識別でき、ネイティブブラウザーに表示されないUSBペアリング端末の再発見に使用できる。

Macアプリは既にOSペアリング済みの端末を別の初回操作なしで検出できるよう、無線で診断サービスを実際に開いて確認する。USB接続中の成功を無線成功とは扱わず、ケーブルを外してから再確認する。後でOSペアリングが切れてもMochiLog側の登録を消さず、再検索またはOSペアリングだけの再実行を案内する。

今後iOS/macOSに一般利用者向けの無線OSペアリングや解析ログの権限付き提供が追加されたら、**OSペアリングだけ**差し替え可能か検証する。確認項目は、未ペアリングの端末、デベロッパモードが一度も有効になっていない端末、App Store配布版、Xcode未導入のMac、iPhone/Watch両方のAnalyticsログ、再起動後の継続性。

資料:

- [Apple: Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)
- [Apple: このコンピュータを信頼](https://support.apple.com/en-gb/109054)
- [Apple: Wi-Fi同期の初回設定](https://support.apple.com/en-sa/guide/mac-help/wi-fi-syncing-mchlada1d602/mac)
- [Apple: DeviceDiscoveryUI](https://developer.apple.com/documentation/devicediscoveryui)
- [Apple: 診断ログの取得方法](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)
- [pymobiledevice3: iOS 17+接続経路](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md)
