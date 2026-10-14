# MochiLog Mac 0.2.31 Beta

## 日本語

診断ファイルの読み取りを拒否された際、同じ保存元の残りのファイルをその回で繰り返し取得しないようにしました。未取得のファイルは再試行待ちとして残し、次回は同じ日付の未試行ファイルを優先します。iPhone本体とApple Watchは別々に扱い、一方の拒否で他方を止めません。

スマホから認証済みの通信で受け取ったLANアドレスを、最大24時間、予備の接続候補として利用します。最初の1時間を過ぎると、以前OS認証が成功した接続先を先に試します。接続時のOSペアリング認証は従来どおり必要です。既存のペアリング、当日分がそろった後の停止、未転送ログの保護は維持します。

読み取り停止の理由、保留件数と再試行を動作ログに記録します。

## English

When a diagnostic file open is denied, collection now holds the remaining files from that source for the current attempt instead of repeatedly requesting them. Held files remain pending. The next attempt prioritizes untried files from the same date, so one permanently unreadable file does not starve other reports. iPhone and Apple Watch sources are handled independently.

LAN addresses received through authenticated mobile requests remain available as fallback candidates for up to 24 hours. After the first hour, a previously OS-authenticated endpoint takes priority. Every connection still requires the existing OS pairing authentication. Existing pairings, automatic daily completion and pending-file protection remain compatible.

Activity logs record source read-gate triggers, held counts and retry decisions.
