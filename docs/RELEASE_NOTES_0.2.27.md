# MochiLog Mac 0.2.27 beta

## 日本語

新しいバッテリーログを優先して取得するようにしました。古いファイルが権限エラーなどで読めないときは、ファイルごとに再試行を待つため、同じ失敗を収集のたびに繰り返しません。当日のファイルは短い間隔で再試行し、失敗したログを転送済み・対象外として扱うことはありません。

当日のiPhone・iPad・Apple Watchのログが端末内に見つかった時点と、取得に失敗した理由・次回再試行時刻をデバッグログに記録します。ログの生成待ちと、取得・転送の遅延を調べやすくしました。

既存のペアリング、暗号化、記録の重複防止、未転送ログの保護を維持しています。Windows版にも同じ収集修正を反映しています。

## English

Newer battery reports are collected first. When an older file cannot be read because of a permission or transport error, retries are scheduled per file instead of repeating the same failure on every collection. Reports for the current day use a shorter retry interval. A failed read is never marked as delivered or permanently excluded.

Debug logs now record when today's iPhone, iPad and Apple Watch reports first appear in the device listing, along with per-file failure reasons and the next retry time. This helps distinguish report availability from collection or transfer delays.

Existing pairing, encryption, duplicate prevention and protection of unsent reports are preserved. The same collection fixes are available in the Windows companion.
