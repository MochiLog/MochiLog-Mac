# MochiLog Mac 0.2.19 Beta

## 日本語

今回の更新：同じPCとペアリングしたiPhone・iPadで、双方のiCloud同期がオン・同じApple Accountと確認できた場合だけ、ほかの端末のログも暗号化して受信します。3台・4台でも受信先ごとに条件を確認し、同期オフ・別アカウント・未確認なら共有しません。共有元のアプリをしばらく開いていない場合は確認まで保留します。元端末の個体IDとWatchの区別を保持し、同じログの重複転送・重複記録を回避します。別の端末が受信しても元端末向けの未転送ログは保護します。旧版とは自分の端末のログを従来どおり扱い、既存ペアリングを引き継ぎます。

Mac・Windowsとも日次ログ収集と現在のバッテリー情報を独立して並列動作させます。収集ツール、接続、事前照会、応答準備・送信、受領確認・解析までの経過時間をデバッグログへ追加しました。共有を許可・保留した理由と元端末・受信先も追跡でき、秘密鍵・アカウント照合値・現在のバッテリー値自体は記録しません。Windowsは低速回線で転送が進んでいれば合計25秒を超えても継続し、通信停止にはタイムアウトします。

共有には新しいスマホ4.0.0 (1039)、MochiLog Mac 0.2.19 Beta / Windows 0.1.16 Alphaが必要です。PC同士は同期しません。PCが削除済みのログは復元できません。許可の通知が通信不能で届かない場合、PCが保持する直前の許可は最大15分で期限切れになります。実際のCloudKit・モバイル回線・OSの条件で差があるため、ベータ版としてご確認ください。

## English

This update adds encrypted sharing of logs between iPhone and iPad paired with the same computer, only when both have iCloud sync enabled and the same Apple Account is confirmed. Conditions are checked per recipient with three or four devices too. Sync off, different accounts or unconfirmed settings prevent sharing. If the source app has not been opened recently, sharing waits for confirmation. Source and Watch identities are preserved, and duplicate transfers and records are avoided. Another recipient’s ACK protects the source’s pending queue. Existing pairings and own-device transfers remain compatible with earlier versions.

Mac and Windows now run daily-log collection and current battery acquisition independently and in parallel. Debug logs trace collection jobs, connection, preflight decisions, response preparation/write, application acknowledgement and parsing times. Sharing reasons, source and recipient are recorded without secret keys, account-matching scopes or battery values themselves. Windows allows progressing slow transfers to exceed 25 seconds overall, while timing out stalled communication.

Sharing requires mobile 4.0.0 (1039), MochiLog Mac 0.2.19 Beta / Windows 0.1.16 Alpha. Computers do not synchronize with each other, and deleted raw logs cannot be recovered. If a device cannot send revocation, the computer’s previous consent expires within 15 minutes. Actual CloudKit, cellular and OS conditions vary; this remains a beta feature.
