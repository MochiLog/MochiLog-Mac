# PC連携の権限・失敗診断（2026-11-18）

- 収集自体が例外で終了したとき、診断JSONが失敗0件になっていた。失敗1件・未完了として保存するよう修正し、実際のタイムアウト報告を書き出す回帰試験を追加した。
- 端末画面にローカルネットワークの明示的な確認、拒否時の警告、システム設定への入口を追加した。QR作成時にも確認を開始する。確認には8秒の期限を設け、設定から戻った際は既知の拒否を再確認する。
- Info.plistにアプリと同梱ヘルパーで使うBonjourサービス種別を宣言した。これが既存の問い合わせの唯一の原因だったとは主張しない。
- 警告は公開Network APIの観測に基づく。古いプロセスの拒否・一般のタイムアウト・単にlistenerが開いたことを現在の権限の証明にしない。TCC DBや非公開APIは使わず、Tailscaleの有効な経路を警告だけで止めない。
- iPhone/iPadと同じ8言語の案内と、同一内容のNetworkAccessDiagnostics / PCNetworkPermissionCheckを使用する。

根拠は[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。Terminal / SSHからの実行はmacOSのローカルネットワーク制限の例外になるため、CLI試験の成功をGUIアプリの権限許可の証拠にはしない。

ネイティブ暗号化プロトコル・受領ACK・再送拒否・複数端末の所有権・診断1000回の書き出し・子プロセス制限の試験と、Macアプリ全体のビルドが成功。実機の権限を拒否へ変更する試験は行っていない。

スマホ側のEOF待ち・不在PC・Bonjour変動・サイズ超過・認証エラーからの回復は[共通クライアントの検証記録](https://github.com/MochiLog/MochiLog/blob/main/docs/PC_LINK_STABILITY_2026-11-18.md)を参照。これらはMac / Windows双方への接続に適用する。既存ペアリングや保存形式は変更していない。
