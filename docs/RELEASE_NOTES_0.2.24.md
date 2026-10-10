# MochiLog Mac 0.2.24 (27) beta

## 日本語

端末通信ヘルパーを、pymobiledevice3を含むNuitkaのネイティブコンパイルへ切り替えました。必要なCPythonランタイムと依存ライブラリはアプリ内へ同梱するため、利用者によるPythonのインストールは不要です。読みやすい元のPythonソースはリポジトリに残しています。既存のペアリング、暗号化、再送防止、収集・転送の形式は維持しています。

ローカルとGitHub Actionsで共通のビルドスクリプトを使い、Python環境のない状態で同梱ヘルパーが起動できることを自動検証します。スマホ4.0.0ベータ1051以降の動作ログは「設定 → デバッグ → 動作ログ」にまとめました。

## English

The device collector now uses native compilation with Nuitka, including the maintained pymobiledevice3 library. Its required CPython runtime and dependencies remain bundled, so users do not need to install Python. Readable Python sources remain in the repository. Existing pairing, encryption, replay protection, and collection/transfer formats are unchanged.

Local builds and GitHub Actions share the same build scripts and automatically verify the bundled collector without a user Python environment. In mobile 4.0.0 beta 1051 and later, daily activity logs are grouped under Settings → Debug → Activity logs.
