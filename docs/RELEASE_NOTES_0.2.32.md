# MochiLog Mac 0.2.32 Beta

## 日本語

外出・ロックなどでログを読み取れなかった後、ファイル別の待機時間と5分ごとの収集がずれ、次の回を逃す問題を修正しました。取得に失敗したファイルは、次の収集で再試行できます。過去の日付の取得失敗にも追加の30分待ちを設定しません。

同じ保存元への連続した読み取り拒否を、その収集中だけ抑える仕組みは維持します。最初に試すファイルを保存元ごとに交代し、1つの読めないファイルで他の日付まで止まらないようにしました。その後は新しい日付のログを優先します。

既にダウンロードしたものの内容をまだ判定できないファイルの再確認待ち、当日分がそろった後の自動休止、重複防止と既存ペアリングは維持します。旧版が残した待機値は元の期限まで残る場合があります。自動収集は5分ごとです。帰宅直後の即時取得を保証する変更ではありません。

## English

Fixed an extra retry delay caused by a per-file failure cooldown drifting past the five-minute collection timer. Failed downloads are eligible on the next collection attempt, including historical files that previously received a further thirty-minute cooldown.

Repeated permission-denied reads from the same source are still held for the current collection only. Each host/accessory rotates its initial probe through untried or least recently attempted reports; the remaining files keep their daily priority. A permanently unreadable first report no longer hides every other date.

Downloaded-but-unclassified content keeps its separate recheck interval. Daily completion stops, duplicate prevention and existing pairings remain compatible. Pre-existing retry deadlines retain their original expiry. Automatic collection still runs every five minutes; this does not guarantee an immediate collection on arriving home.
