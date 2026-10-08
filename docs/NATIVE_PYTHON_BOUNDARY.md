# Pythonとネイティブの役割分担

更新日: 2026-10-08。開発者向けのメモ。利用者がPythonをインストールする必要はない。

## 方針

アプリの状態・UI・ペアリング・暗号化・再送防止・保管庫・収集スケジュール・ログの候補選別はMacのSwift／WindowsのC#で実装する。スマホでの記録解析はSwiftの既存パーサーだけを使用する。PC側にバッテリーログのパーサーは追加しない。

Appleの端末通信は保守されているpymobiledevice3 11.19.1を使う。独自にAppleの通信プロトコルを作り直さない。Pythonはそのライブラリを呼ぶ小さなアダプターとし、ソースをリポジトリのルートにそのまま置く。

| ソース | 担当 | 担当しないこと |
| --- | --- | --- |
| `CollectorEntry.py` | 同梱実行ファイルの起動、ライブラリCLI／2つのアダプターの振り分け、終了処理 | アプリの状態や暗号鍵の保存 |
| `DirectRsd.py` | 既存のOSペアリングを用いた直接IP接続、診断ファイルの一覧取得・ダウンロード | 候補の採否、記録解析、保存期間の判断 |
| `BatterySnapshot.py` | DiagnosticsService.get_battery()、取得タイムアウト、型を保持するplist出力 | 表示項目の選別、数値の意味付け、ハッシュ、取得日時、UI |
| Mac `Sources/LiveBattery.swift`／Windows `Services/LiveBattery.cs` | plist検証、入れ子の展開、表示値の検証、主要・詳細の独立ハッシュ、取得日時、セッション内キャッシュ | 日次のバッテリー記録の解析・保存 |

直接IP接続はTailscaleなどBonjourを使えない経路にも使う。ライブラリの非公開provider差し替えを使用する箇所はコメントで明示してあり、ライブラリ更新時にはUSB・標準Mac経路・直接IPを再確認する。Pythonに残したパス検証はダウンロード境界の安全確認であり、バッテリー内容の解析ではない。

## 現在値の境界

1. Pythonは端末の返す辞書をXML plistにする。整数（UInt64を含む）・真偽値・バイナリ・日時・入れ子を保持する。最大1MiB。
2. ネイティブ側は深さ32、最大10,000項目、キー512文字、値131,072文字、詳細JSON256KiBを上限に検証する。WindowsのXML readerは外部エンティティを解決しない。
3. 意味を確認した正確なパス・型だけを通常の表へ出す。未知の単位、名前が似た入れ子の値、不正な型、表示値と食い違う生値は詳細へ残す。IOReportのチャンネル名を温度の測定値として扱わない。
4. スマホへの転送形式は従来のversion 1の現在値と詳細JSONのまま。旧PythonヘルパーのJSONもネイティブ側で読み取れる。既存の暗号化・ペアリングを変更しない。
5. 現在値はメモリ内だけで扱い、履歴・iCloud・診断ログ・サポート添付へ保存しない。テストのfixtureは架空の値を使う。

## 検証

Pythonのtransportテストは型の保持と上限を確認する。主要値の検証・ハッシュ・任意詳細の分類・旧形式の互換性はSwiftとC#のプロトコルテストに移した。MacとWindowsで同じ架空のXML fixtureを使う。変更後はPythonテスト、ネイティブのプロトコルテスト、各アプリのビルド、iPhone・iPadの表示試験を実施する。

## English

Application logic stays in native Swift on Mac/mobile and C# on Windows. Python is an explicitly documented adapter for the maintained pymobiledevice3 device API. BatterySnapshot transports lossless plist data only; native code validates and flattens it, selects understood rows, generates independent revisions and timestamps, and keeps it in session memory. The encrypted mobile wire format is unchanged, and legacy helper JSON remains accepted. DirectRsd lists and downloads files; candidate selection remains native. No battery-log parser is introduced on the computer. Packaged apps include the runtime and dependency licenses; users do not configure Python.
