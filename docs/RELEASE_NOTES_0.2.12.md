# MochiLog Mac 0.2.12 Beta

## 日本語

iPhone・iPadへ送信済みの電池ログをPC側から削除した後も、取得済みの日付を確認できるようにしました。必要なiPhone本体とApple Watchのログが揃った日は、自動収集を翌日まで休止します。「今すぐログを収集」は引き続き利用できます。

電池ログではない短い解析ファイルを繰り返し取得する問題も修正しました。同じ内容を複数回確認してから対象外にするため、取得途中の電池ログを早まって除外しません。

## English

The Mac now remembers confirmed daily logs after their raw files are delivered and removed. Once the required iPhone and Apple Watch logs are available, automatic collection pauses until the next day. **Collect Logs Now** remains available.

The collector also stops repeatedly downloading short analytics files that are not battery logs. It checks for unchanged content across multiple attempts before excluding a file, so an incomplete battery log remains eligible for retry.
