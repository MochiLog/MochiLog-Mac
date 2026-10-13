# MochiLog Mac 0.2.30 Beta

## 日本語

診断情報をSwiftで定期的に生成・保存する仕組みを追加しました。アプリのメモリ使用量、実行中の端末通信ツール数、端末ごとの接続候補、収集結果と直近の動作を記録し、サポートの添付にも含めます。件数・文字数・サイズに上限を設け、診断ファイルを読み込む前にもサイズを制限します。

端末通信ツールの実行時間、出力量、メモリ使用量の監視を強化しました。時間切れ、キャンセル、出力超過時には関連するプロセスを止め、親プロセスの終了後に子プロセスだけが残るケースにも対応します。現在のバッテリー取得やペアリングにも適用しています。

サポートの添付準備をバックグラウンドへ移し、日付別ログは丸ごとメモリに読み込まずファイルとしてコピーします。既存のペアリング、未転送ログ、スマホとの通信方式は維持されます。

設定に「常駐時に画面のメモリを解放」を追加しました。初期設定はオンです。画面を閉じる・最小化する・アプリを隠すと画面を破棄し、再表示時に直前のページを作り直します。入力途中のフォームはリセットされます。オフにするとこの画面破棄を行いません。収集・転送は継続します。設定と説明は8言語に対応しています。

## English

Swift now produces bounded diagnostic snapshots automatically, covering process memory, active device helpers, per-device connection candidates, collection results and recent activity. Fresh snapshots are included in support attachments. Report counts, text lengths and total size are bounded, and diagnostic files are capped before decoding.

Device helpers now share supervised execution with runtime, output and memory checks. Timeout, cancellation and output overflow stop the owned process group, including descendants that retain output pipes after their parent exits. The same supervision covers live battery queries and pairing.

Support attachments are prepared off the UI thread, with daily archives copied directly instead of loaded and re-encoded in memory. Existing pairings, pending battery logs and mobile protocol compatibility are preserved.

Settings now includes **Release screen memory in the background**, enabled by default. Closing, minimizing or hiding the window discards its screen; reopening rebuilds the last page. Unsubmitted forms reset. Turn it off to disable this explicit screen teardown. Background collection and transfers continue. The setting and explanation support all eight languages.
