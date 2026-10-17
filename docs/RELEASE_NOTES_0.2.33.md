# MochiLog Mac 0.2.33

## 日本語

- Apple Watchの古いログ用フォルダを確認できなくても、現在のログ用フォルダから取得を続けるよう改善しました。
- 一部のログ一覧を確認できなかった場合は、取得できたログを保存し、残りは次回自動で再試行します。未確認の一覧があるのに取得完了と表示される問題を修正しました。
- 一覧取得の失敗をファイル取得の失敗と分けて診断ログに記録します。接続が戻った後の再試行間隔は延ばしていません。
- 既存のペアリングを引き継ぎます。暗号化、再送防止、受信済みログの事前確認、確認応答の仕組みは維持しています。
- 新しい案内を8言語に対応させました。

## English

- Current Apple Watch reports can still be collected when their archive directory is unavailable.
- Available reports are saved even if another directory cannot be checked. Unchecked directories are retried automatically, and partial listings no longer appear as completed acquisition.
- Diagnostic logs now distinguish directory-listing failures from file-download failures. The normal retry interval has not been extended.
- Existing pairings are retained. Encryption, replay protection, duplicate preflight checks and receipt acknowledgements are unchanged.
- The new partial-result explanation is available in all eight supported languages.
