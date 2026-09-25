# MochiLog Mac

MochiLogのiOS/iPadOS 27向けワイヤレスログ転送機能のMac用ベータアプリです。macOS 27以降に対応します。Macが解析ログを取得して保持し、iPhone/iPadでMochiLogを開いたときにローカルネットワークで暗号化して転送します。解析と記録はiPhone/iPad側で行います。

## 利用手順

1. 署名済みDMGを開き、`MochiLog Mac.app`をApplicationsへコピーします。Python、Xcode、Homebrewの追加インストールは不要です。
2. iPhone/iPadとMacを同じWi-Fiに接続し、Bluetoothをオンにします。初回OSペアリング時のみiPhone/iPadのデベロッパモードをオンにし、Macアプリの案内に従って6桁コードを入力します。完了後はオフに戻せます。
3. Macアプリで端末を選んでMochiLogペアリングを作成し、iPhone/iPadのMochiLogの「設定 → 高度な設定 → Mac連携」でQRコードを読み取ります。QRコードには秘密鍵が含まれるため共有しないでください。
4. Macアプリを起動したままにすると定期的にログを収集します。iPhone/iPadのMochiLogを開くと転送と取り込みが始まります。

ベータ版です。端末探索やログ取得には端末のロック解除が必要な場合があります。iOS 16の端末はMochiLog本体を引き続き使えますが、このMac連携機能の対象外です。

## ビルド

開発者はXcode 27、XcodeGen、fastlane、Python 3とDeveloper ID Application証明書を用意し、`fastlane mac beta_dmg`を実行します。完成した配布物は`Build/MochiLog-Mac-Beta.dmg`です。使用者側にはこれらの依存は不要です。公証用のkeychain profileがある場合は`MOCHILOG_NOTARY_PROFILE=<profile> fastlane mac notarize_beta`で公証・stapleします。

`pymobiledevice3`およびビルド時依存のバージョンは`requirements-build.txt`で固定しています。ライセンスは`LICENSE`と`THIRD_PARTY.md`を参照してください。
