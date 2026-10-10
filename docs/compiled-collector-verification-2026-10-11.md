# コンパイル済み端末通信ヘルパーの検証（2026-10-11）

## ローカルMac

- Nuitka 4.3、pymobiledevice3 11.19.1、Homebrew Python 3.13.16。並列数1。
- 全体をstandalone形式へコンパイル。Macの実行名は`mochilog-collector`。同名のライブラリ用リソースフォルダーとの衝突を回避する。
- `scripts/test-compiled-collector.py`成功。ソースとvenvの外へ移し、PythonのないPATHと無効なPYTHONHOME/PYTHONPATHで起動。
- 診断・crash reports・トンネル・アダプターの7モジュールが`__compiled__`を持つことを実行時に確認。CLIの7経路、型保持plist、ChaCha20-Poly1305、TLS証明書、プラットフォームproviderを検証。
- standaloneは267,598,505 bytes、オフライン試験18.753秒。CPythonランタイムは同梱されており、Pythonそのものが不要になったという意味ではない。
- 実機の既存OSペアリングを変更せず、コンパイル済み`battery-snapshot`からiPhone 17（311末端項目、0.71秒）とiPad（323末端項目、0.67秒）の型付きplistを取得。値の内容やペアリング秘密情報はこの報告へ保存しない。
- ネイティブ暗号転送・再送防止・Watchの分離・保存とACKの試験、およびPythonアダプター6試験は成功。

## 配布時の確認

署名・公証、完成DMG、Windowsインストーラー内での起動は別の工程。上記だけを根拠に、それらの成功を主張しない。GitHub Actionsの最終結果と実機更新の記録を追記する。

## コンパイル単体CI

[38065819457](https://github.com/MochiLog/MochiLog-Mac/actions/runs/38065819457)は成功。CIのPython 3.13.16環境でも7経路・型付きplist・暗号・証明書の独立起動試験が合格（5.697秒、275,533,225 bytes）。署名付きの初回実行38065821187はNuitkaの署名段階で失敗し、アプリ／DMGは未作成。失敗詳細が十分に出なかったため、コンパイラーと配布用署名を分離し、`sign-collector.py`で全Mach-Oを個別署名・検証する方式へ変更した。CIのPythonはローカルで確認済みのHomebrew版に揃えた。署名付きの再実行の結果を待って公開する。

## 最終の署名・公証と実機更新

[38068654882](https://github.com/MochiLog/MochiLog-Mac/actions/runs/38068654882)成功。Homebrew Python 3.13で全体をコンパイルし、Mach-OごとのDeveloper ID署名、Releaseアプリ署名、アプリとDMGそれぞれの公証・staple・検証、署名付き更新フィード生成が完了。

完成DMGをローカルでマウントし、SHA-256（787adcd14037a29ce9faa7f1c24202726b6b8129b1e5e9fbc47eb4a5c81400ca）、codesign strict、stapler、GatekeeperのNotarized Developer ID判定を確認。署名後のヘルパーを独立フォルダーへコピーし、Python環境を無効にした7経路の試験が成功（20.728秒、269,880,745 bytes）。署名後の実機取得もiPhone17で311項目、iPadで323項目の型付きplistを確認。

`/Applications/MochiLog Mac.app`を0.2.24（27）へ更新して起動を確認。既存設定・ペアリング・保管庫は保持。GitHubのv0.2.24ベータを公開し、生成済みの署名付きappcast.xmlを改変せず反映。今後のDMGスクリプトにも署名後の独立起動試験を追加した。
