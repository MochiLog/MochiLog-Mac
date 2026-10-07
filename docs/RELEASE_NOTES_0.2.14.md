# MochiLog Mac 0.2.14 Beta

## 日本語

日次ログとは別に、ペアリング済みiPhone・iPadの現在の充放電回数・設計容量・最大容量などを確認できるベータ機能を追加しました。PCの概要画面に端末別で表示し、スマホの高度な設定でオンにすると専用タブでも表示できます（初期状態はオフ）。既存のペアリングを引き継ぎます。

アプリを開いている間に定期取得し、変化した値だけを暗号化して転送します。最終取得日時、欠けている項目、取得失敗時の古い値を区別し、今すぐ受信／送信・PCへの更新要求にも対応します。現在値はメモリだけで扱い、履歴・記録・iCloud・診断ログには保存しません。

取得にはpymobiledevice3の診断APIを使用します。機種・OS・接続状態によって取得できない項目があります。ロック中の取得成功を確認していますが、常に成功することや日次ログのロック中取得を保証するものではありません。Apple Watchの現在値は対象外です。スマホの新しい4.0.0ベータと組み合わせてください。

## English

Added a beta view of current cycle count, design capacity and other capacity fields for paired iPhones and iPads, separate from daily Analytics logs. Each device has a card on the computer dashboard. Enable Live Battery in the mobile app’s Advanced Settings to show a dedicated tab; it is off by default. Existing pairings are preserved.

While the app is open, values refresh periodically and only changed values are transferred using encryption. Acquisition time, unavailable fields and outdated values after a failed refresh are shown separately. Receive Now, Send Now and mobile requests to refresh the computer are available. Values remain in memory only and are never saved to history, records, iCloud or diagnostic logs.

Acquisition uses the maintained pymobiledevice3 diagnostics API. Field availability depends on device, OS and connectivity. A locked query has succeeded in testing, but this does not guarantee all locked queries or locked-state daily Analytics collection. Live Apple Watch values are not included. Use with the new MochiLog 4.0.0 beta.
