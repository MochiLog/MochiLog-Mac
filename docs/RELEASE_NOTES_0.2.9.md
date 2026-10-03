# MochiLog Mac 0.2.9 Beta

## 日本語

当日のiPhoneと既知のApple Watch、またはiPadの解析ログを保管できた後は、その端末の自動再走査を翌朝まで休止します。転送待ちの接続は維持し、「今すぐログを収集」は引き続き利用できます。Watchの有無を確認できないiPhoneは早まって休止しません。停止と再開の理由・時刻をデバッグログに記録します。

複数端末やWatchログを利用している方は、当日の必要なログがそろった後に5分ごとの再走査が止まり、MochiLogを開いた際に保管済みファイルを受信できるか確認してください。

## English

Once today's iPhone and known Apple Watch logs, or today's iPad log, are safely stored, automatic rescans for that device pause until the next morning. The transfer listener stays available, and “Collect Logs Now” still works. An iPhone whose Watch status is unknown does not pause prematurely. The debug log records when collection stops or resumes and why.

If you use multiple devices or an Apple Watch, please check that repeated five-minute scans stop after the required files are stored and that MochiLog can still receive queued files when opened.
