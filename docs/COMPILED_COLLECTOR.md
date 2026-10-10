# 端末通信ヘルパーのコンパイル

## 方針

pymobiledevice3 11.19.1とMochiLogの小さなPythonアダプターをNuitka 4.3でCを経由したネイティブコードへコンパイルする。独自の端末通信実装へ移植しない。CPythonランタイムと依存ライブラリは引き続き必要なためアプリ内に同梱する。**利用者のPython環境には依存しない**。読みやすいPythonソースはリポジトリに残す。Swift／C#から呼ぶプロセス境界・認証・転送形式・既存ペアリングは変更しない。

standaloneフォルダーをDMG／インストーラーへ丸ごと格納し、毎回展開するonefile形式を使わない。エントリーポイント・CLI・診断サービス・無線トンネルのモジュールがコンパイルされたことを実行時に確認する。暗号拡張、TLS証明書、動的schema、WindowsのWintun DLLも梱包検証に含める。コンパイルは秘密保持や改ざん耐性の代わりにはならない。

## 開発用の前提

Python 3.13、OS向けCコンパイラー、ネットワーク接続が必要。開発者／CI用で、利用者にインストールを求めない。MacはHomebrew／python.orgのPythonとXcode Command Line Tools、WindowsはPythonとVisual StudioのMSVC C++ビルドツールを使う。MacのpyenvはNuitka standalone対象外なのでビルド前に拒否する。

## ローカル

Mac:

```sh
MOCHILOG_PYTHON_BIN=/opt/homebrew/bin/python3.13 MOCHILOG_COMPILER_JOBS=1 bash scripts/build-collector.sh
# 署名済みDMG（既存Developer ID／公証設定を使用）
MOCHILOG_PYTHON_BIN=/opt/homebrew/bin/python3.13 MOCHILOG_COMPILER_JOBS=1 fastlane mac beta_dmg
fastlane mac notarize_beta
```

Windows（MochiLog-Windowsリポジトリ内）:

```powershell
./scripts/build-collector.ps1 -Python python -Jobs 1
./scripts/build-installer.ps1 -Python python -CompilerJobs 1
./scripts/test-installer.ps1
```

共有の`compile-collector.py`を両OSのラッパーから呼び出す。出力は`Build/Collector`。Macの実行ファイル名は`mochilog-collector`、Windowsは`pymobiledevice3.exe`。Macではライブラリのリソースディレクトリ`pymobiledevice3/`と実行ファイル名が衝突しないようにする。依存の固定は`requirements-build.txt`、DLL設定は`scripts/collector.nuitka-package.config.yml`。単体ヘルパーと配布用ビルドで同じスクリプトを使う。並列数はローカル初期値1、CIは2。各OSのバイナリは各OS上で生成する。

## CI

Macの`Compiled collector verification`はmainへのpush／PRで実行する。`Signed beta DMG`は手動実行で既存の署名・アプリ／DMG公証・成果物ダウンロードを継続する。Windowsの`Build Windows alpha installer`はmainへのpush／PRと手動実行に対応し、コンパイル・プロトコル試験・ネイティブビルド・インストール／アンインストール試験を行う。CIはReleaseを作らず成果物を保存する。

両OSともビルドの最後に`test-compiled-collector.py`を実行する。フォルダーをソース／venvの外へコピーし、PATHからPythonを除き、PYTHONHOME／PYTHONPATHを存在しないパスへ設定する。CLIの遅延import、ライブラリバージョン、型を保持するplist、暗号化、TLS roots、プラットフォームproviderを検証する。Windowsは完成したインストーラーの配置先でも再検証する。`compilation-report.xml`はCIで14日保存する。

実端末のUSB／Wi-Fi／Tailscale収集、OSのロック状態、初回信頼、署名／公証の成功は別の検証であり、オフライン試験だけでは成功を主張しない。
