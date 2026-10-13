# MochiLog Mac 0.2.29 Beta

## 日本語

- Macのネイティブ診断経路が使えないとき、スマホから暗号化して受け取ったLAN候補をOSの既存ペアリングで認証して試します。IP変更やVPNによる転送元と診断先の違いを区別します。
- 取得失敗や再試行待ちがある場合に、復旧・完了と誤って表示しないよう修正しました。待機件数の表示は8言語に対応しています。
- 新しい接続先通知にはMochiLog 4.0.0ベータ1057が必要です。古い版との通信と既存のペアリングは維持されます。
- 端末はログ収集中にロック解除が必要です。ログが未生成の場合やOSが読み取りを拒否する場合まで解決したことを意味しません。

## English

- When the native Mac diagnostic route is unavailable, authenticated, encrypted LAN hints from the mobile app provide fallback endpoints, each verified with the existing OS pairing record.
- Failed downloads, deferred classification and retry waiting no longer count as recovery or completed acquisition. Waiting counts are localized in all eight languages.
- New endpoint hints require MochiLog 4.0.0 beta 1057. Existing pairings and communication with older versions are retained.
- Mobile devices must be unlocked for log collection. This update does not bypass OS access restrictions or generate missing Analytics logs.
