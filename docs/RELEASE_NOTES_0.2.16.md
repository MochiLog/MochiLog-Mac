日本語

現在のバッテリー画面を「項目／値」の表に変更しました。容量・充放電回数・充電状態・外部電源・電圧・電流など、意味を確認した項目を表示します。取得できない項目は区別します。

内部値・不明なコード・チャンネル情報などは、初期状態で閉じた「詳細情報を表示」から任意に確認できます。未知の単位や意味は推測せず、大きな整数も丸めません。チャンネル名を実際の温度測定値として扱いません。

Pythonは保守されているpymobiledevice3による端末接続・API呼び出し・データ出力に絞り、項目選別・検証・ハッシュ生成・取得日時とログ候補選別をSwift／C#へ移しました。ソースと役割の説明をリポジトリで読めます。必要な実行環境は同梱し、ユーザーの環境構築は不要です。

既存のペアリングと暗号化通信を引き継ぎ、旧版の主要項目表示も維持します。現在値はメモリ内だけで扱い、履歴・記録・iCloud・サポートログには保存しません。新規取得の可否は端末の診断サービスと接続条件に依存します。日次AnalyticsやApple Watchの現在値を取得する機能とは別です。

English

Live Battery now uses a field/value table for understood readings such as capacity, cycle count, charging, external power, voltage and current. Unavailable readings are shown separately.

Internal values, unknown codes and channel metadata remain under Show detailed information, collapsed by default. Original names and values are preserved without guessing units or meanings. Large integers keep their precision; a channel name is not treated as an actual temperature measurement.

Python is limited to the maintained pymobiledevice3 device connection, API calls and data output. Field selection, validation, hashes, acquisition timestamps and log-candidate selection now run in native Swift/C#. Readable adapter sources and architecture notes are in the repositories. Runtime dependencies remain bundled; users do not configure Python.

Existing encrypted pairings and older clients’ core-field views are preserved. Current values stay in memory only, never in history, records, iCloud or support logs. Fresh acquisition depends on the device diagnostics service and connectivity. This is separate from daily Analytics files and live Apple Watch values.
