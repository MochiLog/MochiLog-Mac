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
