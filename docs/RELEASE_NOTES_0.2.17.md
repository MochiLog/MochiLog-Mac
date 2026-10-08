日本語

現在のバッテリーの通常表を、公開定義で意味と単位を確認できた正確なパスの項目に限定しました。公称容量・生の最大容量・満充電容量、表示残量の単位が未確定の値、BatteryData内の容量値などは「詳細情報を表示」へ移しました。元の値は失わず、単位を推測しません。設計容量は確認できたルート項目がない場合に未取得と表示します。

Pythonはpymobiledevice3の接続とAPI呼び出しに絞り、検証・分類・ハッシュ・取得日時とログ候補選別はSwift／C#で行います。ソースと役割をリポジトリで読めます。既存のペアリング・暗号化・旧版の転送形式を維持します。現在値はメモリ内だけで扱い、履歴・iCloud・サポートログには保存しません。

English

The normal Live Battery table now uses only exact paths with publicly documented meanings and units. Nominal, raw maximum and full-charge capacity, ambiguous charge-level units, and nested BatteryData capacities are retained under Show detailed information without guessing units. Design capacity is unavailable when the verified root field is absent.

Python remains a maintained pymobiledevice3 connection/API adapter; validation, classification, hashes, timestamps and log selection run in Swift/C#. Readable sources and architecture notes are in the repositories. Existing encrypted pairings and older wire formats are preserved. Values stay in memory, never in history, iCloud or support logs.
