# 日本語

- 当日分の短い・未完成の取得結果を、30分待たず5分間隔で取り直せるようにしました。対象外の判定は十分な間隔で3回確認する条件を保ち、取得途中のログを早く捨てないようにしています。
- 収集の試行ID、候補一覧、取得要求、保存・保留と再試行予定を診断ログへ追加しました。Watch候補がいつ取得元に現れたか、取得と転送のどちらで待っているかを調べやすくしています。
- 同じ接続エラーをCLI日時やプロセス番号の違いで別エラーとして数える問題を修正しました。
- 診断接続の失敗段階と空の一覧を区別し、TCP書き込みとスマホ側の受領・処理を診断ログで明確に分けました。
- 既存のペアリング・記録・受領済みログは維持します。スマホ版の入れ替えや再ペアリングは不要です。

# English

- Retry incomplete or unclassified current-day reports every five minutes instead of holding them for thirty minutes. Permanent exclusion still requires three identical non-empty observations spaced at least thirty minutes apart; quick retries cannot discard an unfinished report early.
- Added collection attempt IDs, candidate listings, download requests, storage outcomes and retry times to diagnostics, distinguishing acquisition delays from transfer and mobile processing.
- Group repeated connection failures by their actual reason instead of treating changing CLI timestamps and process IDs as different failures.
- Report the failed diagnostic connection stage and reject empty root listings. TCP writes are explicitly separate from mobile receipt and processing.
- Existing pairings, records and acknowledged reports remain intact. No mobile update or re-pairing is required.
