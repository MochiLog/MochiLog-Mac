# MochiLog Mac 0.2.34 Beta

## 日本語

今後の改善を続けやすくするため、内部コードの整形と保守用設定を整えたメンテナンス版です。

- Swift・Pythonの字下げ、長い式や引数の改行を統一し、ソースを読みやすくしました。
- 既存のペアリング、暗号化転送、受信済み確認、確認応答、ログの保管設定を引き継ぎます。
- 0.2.33で改善した、Apple Watchの現在のログと古いログ用フォルダを独立して確認する処理を含みます。一部の一覧を読めなくても取得できたログを保存し、未確認分は次回再試行します。
- 暗号化・再送防止・複数端末の共有条件・確認応答・保管庫の既存テストと、Pythonの回帰テストを確認しました。
- 配布アプリと同梱の収集ツールはネイティブコンパイル版です。利用者によるPythonなどの環境構築は不要です。

日次解析ログの収集時はiPhone・iPadのロック解除が必要です。

## English

This maintenance release standardizes internal source formatting and development settings to make future fixes easier to maintain.

- Swift and Python indentation, long expressions and argument lists now follow consistent formatting.
- Existing pairings, encrypted transfers, received-file checks, acknowledgements and log-storage settings are retained.
- Includes the 0.2.33 improvements that check current and archived Apple Watch directories independently. Available logs are saved even when another directory cannot be listed, and unchecked work is retried later.
- Existing encryption, replay protection, multi-device consent, acknowledgement and storage tests, together with Python regression tests, were verified.
- The app and its bundled collector are native compiled distributions. Users do not need to install Python or configure a development environment.

Daily Analytics collection requires an unlocked iPhone or iPad.
