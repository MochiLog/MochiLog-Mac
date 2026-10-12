# MochiLog Mac 0.2.28 beta

## 日本語

- iPhone・iPadとの日付別デバッグログ交換で、送信中に増えたログを今回の受信範囲へ混ぜず、保存済み位置から正確に再開します。旧版との通信も引き続き利用できます。
- デバッグログの受信進捗、保存先の日付、受信範囲の完了、重複した断片の拒否を記録し、サポート時に途中で止まった位置を追いやすくしました。
- 診断ログの取得に使った経路を記録します。ツールがエラーを報告した場合の「終了コード0で停止」という紛らわしい表示を修正しました。

## English

- Daily diagnostic history now resumes from saved byte offsets within the advertised snapshot, even when the original log grows during an exchange. Older companion and mobile versions remain compatible.
- Diagnostic events identify the day, stored progress, completion of the advertised range, and rejected duplicate chunks, making interrupted exchanges easier to investigate.
- Collection diagnostics identify the selected device transport. An error reported by a successfully exited helper is now described as a reported error instead of an exit-code-zero failure.
