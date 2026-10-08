# MochiLog Mac 0.2.20 Beta

## 日本語

今回の更新では、双方のiCloud同期がオン・同じApple Accountと確認できた端末同士で、現在のバッテリー値も共有します。既存ペアリング・旧版の自分の端末の転送は維持し、同期オフ・別アカウント・未確認では他の端末の値を共有しません。現在値はメモリ内だけで扱い、履歴や診断ログには保存しません。

自動更新確認は初期状態でオフです。最初の選択画面と設定で有効にできます。手動の更新確認はこれまで通り使えます。スマホの「自動ログ収集」へ案内を更新しました。

新しいスマホの端末内取得（実験機能）では、認証済みの暗号化接続を使い、その端末自身のOSペアリング情報を明示的に引き継げます。ほかの端末の鍵は渡しません。VPN／リフレクターなどの対応経路と初期OS信頼設定が必要で、MochiLogのQRだけでOS信頼設定を作る機能ではありません。初回設定の完全無線化・バックグラウンド・Developer Modeオフでの取得を保証しません。

共有と引き継ぎにはスマホ4.0.0 (1041)、Mac 0.2.20／Windows 0.1.17以降が必要です。許可の取り消しが通信不能でPCへ届かない場合、直前の許可は最大15分で期限切れになります。

macOS 27、iOS/iPadOS 27以降向け。署名・公証付きDMGです。

## English

This update also shares current battery values between devices with confirmed iCloud sync enabled on the same Apple Account. Existing pairings and older own-device transfers remain compatible. Sync-off, different-account and unconfirmed cases do not share other devices’ readings. Current values remain in memory and are not saved to history or diagnostic logs.

Automatic update checks are off by default. Choose in the initial prompt or settings; manual checks remain available. Mobile navigation now points to Automatic Log Collection.

Experimental on-device collection in the new mobile beta can explicitly reuse its own OS pairing over an authenticated encrypted connection. Another device’s keys are never exported. It still requires a compatible VPN/reflector route and initial OS trust. The MochiLog QR alone does not establish Apple OS trust. Fully wireless initial setup, background collection and Developer Mode-off operation are not guaranteed.

Sharing and pairing reuse require mobile 4.0.0 (1041), Mac 0.2.20 or Windows 0.1.17. If a device cannot deliver revocation, previous computer-side consent expires within 15 minutes.

Signed and notarized DMG for macOS 27 and iOS/iPadOS 27 or later.
