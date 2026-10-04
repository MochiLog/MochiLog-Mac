# MochiLog Mac 0.2.10 Beta

## 日本語

解析ログの取得を端末側の制約で後から再試行する場合、その状態を収集失敗と誤表示しないよう修正しました。Mac側の状態表示とサポート用診断情報で、再試行待ちと実際のエラーを区別できます。

TestFlight版MochiLogとの実機転送を確認しました。既存の記録を再送しても、iPhone側で重複として判定され、記録は増えませんでした。

iOS/iPadOS 27向けのベータ版です。解析ログの収集時は端末をロック解除してください。

## English

Deferred analytics-log collection is no longer reported as a collection failure. The Mac app and support diagnostics now distinguish a pending retry from an actual error.

Device transfer was verified with the TestFlight build of MochiLog. Resending an existing record was recognized as a duplicate on the iPhone and did not create another record.

This beta targets iOS/iPadOS 27. Keep the device unlocked while collecting analytics logs.
