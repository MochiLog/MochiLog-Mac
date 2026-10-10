# MochiLog Mac 0.2.23 Beta

## 日本語

診断ログを日付・機能別のファイルに分割しました。背景実行、端末内取得、PC転送、現在のバッテリー、同期、ペアリングを区別し、未知のメッセージも一般ログとして保持します。

各ファイルの先頭に形式バージョン2、アプリとビルド番号、作成日時とタイムゾーンを記録します。旧ログは旧形式のまま扱い、行ごとにメタデータを繰り返しません。従来のスマホとの暗号化された診断ログ交換・日付別表示・サポート添付には互換用の集約ファイルを使用し、受信済みのバイト位置を維持します。保存期間変更と削除は機能別ファイルにも適用します。

既存の収集・転送・暗号化・現在のバッテリー情報の機能は継続します。

## English

Diagnostics are now stored in separate daily files for background activity, on-device collection, PC transfers, current battery information, cloud sync, pairing, and general events.

Each file has a format-version-2 header with app/build, creation time and time zone. Metadata is not repeated on each line. Historical logs retain their legacy format. An append-only compatibility stream preserves existing encrypted diagnostic exchange, day-based viewing, support attachments, and previously received byte offsets. Retention and deletion also remove the feature files.

Existing collection, transfer, encryption, and current battery functionality remain available.
