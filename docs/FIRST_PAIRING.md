# 初回の無線ペアリングに関する調査（2026-09-26）

目標は、利用者がUSBケーブルもデベロッパモードも使わずに初回設定し、その後MacがiPhone/iPadの解析ログを自動収集すること。

現在の実装には異なる2種類のペアリングがある。

1. **OSペアリング**: Macの収集ツールが端末の診断ログサービスにアクセスするための信頼設定。`pymobiledevice3 remote pair-host`を使い、iOS/iPadOS 27の「設定 → デベロッパ → ペアリング済みMac」から端末側で開始する。初回はデベロッパモードが必要。完了後はオフに戻せる。
2. **MochiLogペアリング**: QRコードでMacアプリとiPhone/iPadアプリの暗号化通信を設定する。初回から無線で可能だが、アプリの通信権限だけでOSの解析ログ閲覧権限は得られない。

Appleが案内する通常の「このコンピュータを信頼」およびWi-Fi同期も、初回はケーブルで接続する。`pymobiledevice3`のWi-Fi lockdown経路は既存の信頼レコードを再利用するもので、新しい端末の初回信頼設定を代替しない。DeviceDiscoveryUIはアプリ間の無線接続を提供するが、解析ログへのアクセスを許可するAPIではない。

したがって、**初回も無線・デベロッパモードなし・解析ログの自動取得**を同時に満たす、公開された対応方法は現時点で確認できていない。手動共有は無線で可能だが、自動収集にはならない。接続済み端末で読み取れることを、未ペアリング端末への初回アクセスが可能である証拠として扱わない。非公開APIや既存ペアリング鍵の流用を初回設定の代替として案内しない。

今後iOS/macOSに一般利用者向けの無線OSペアリングや解析ログの権限付き提供が追加されたら、**OSペアリングだけ**差し替え可能か検証する。確認項目は、未ペアリングの端末、デベロッパモードが一度も有効になっていない端末、App Store配布版、Xcode未導入のMac、iPhone/Watch両方のAnalyticsログ、再起動後の継続性。

資料:

- [Apple: Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)
- [Apple: このコンピュータを信頼](https://support.apple.com/en-gb/109054)
- [Apple: Wi-Fi同期の初回設定](https://support.apple.com/en-sa/guide/mac-help/wi-fi-syncing-mchlada1d602/mac)
- [Apple: DeviceDiscoveryUI](https://developer.apple.com/documentation/devicediscoveryui)
- [Apple: 診断ログの取得方法](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)
- [pymobiledevice3: iOS 17+接続経路](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md)
