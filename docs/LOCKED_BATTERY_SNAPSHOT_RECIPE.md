# ロック中のバッテリー情報を診断サービスから読む方式

調査日: 2026-10-07（日本時間）。開発者向けの再現メモ。以下の独立クライアントは調査用であり、製品には採用していない。

2026-10-08追記: 現在値を表示する製品機能は、保守されている **pymobiledevice3 11.19.1 の `DiagnosticsService.get_battery()`** で実装した。既存ペアリングで診断要求が成功し、必要な項目が存在することを確認している。独立クライアントはライブラリで取得できない場合の調査用に残す。日次Analyticsの取得経路とは別で、現在値は記録・履歴・診断ログへ保存しない。結果と単位の取り扱いは [LOCKED_ANALYTICS_RESEARCH.md](LOCKED_ANALYTICS_RESEARCH.md) の末尾、利用方法は [USER_GUIDE.md](USER_GUIDE.md) を参照する。

## 確認できたこと

一度ロック解除した後に再ロックした iPhone 17 / iOS 27.2 (24B5099f) に対し、macOS 27.2 (26B5101f) から既存のOSペアリングを使い、**診断サービスへの読み取り要求が成功した**。

22:05 の再ロック確認、22:06 の日次ファイル試験後、22:07 の診断試験後に `devicectl device info lockState` が `passcodeRequired: true` / `unlockedSinceBoot: true` を返した。再起動後に一度も解除していない状態は対象外。

| 試験 | 時刻（JST） | 応答 | 数値型の値が存在した項目 |
| --- | --- | --- | --- |
| GasGauge | 22:06:25 | Status = Success | CycleCount, FullChargeCapacity |
| IORegistry / IOPMPowerSource | 22:07:10 | Status = Success | AppleRawMaxCapacity, CurrentCapacity, CycleCount, DesignCapacity, FullChargeCapacity, MaxCapacity, NominalChargeCapacity |

クライアントは実際の応答を受け、項目の値が数値型であることまで確認した。保存・表示したのは許可した**項目名**だけであり、個々の数値やバッテリーのシリアル番号は記録していない。数値の単位、精度、日次Analyticsの値との一致もまだ確認していない。名前だけから一律に mAh やパーセントと解釈しない。

同じ再ロック状態で、日次Analyticsファイルの読み取りは `FILE_OPEN: AFC PERM_DENIED (10)` だった。診断スナップショットが読めることと、保存済み日次ログが読めることは別である。

## 接続と要求の流れ

1. 自作Cヘルパーが macOS の `com.apple.CoreDevice.remotepairingd` に既存端末の接続を要求する。既存ペアリングの `CreateAssertionCommand` を使い、新規ペアリングやキー作成はしない。
2. 自作Pythonクライアントが HTTP/2 / RemoteXPC でRSDを探索する。接続先の端末識別子が要求した端末と一致することを検証する。
3. RSDで公開された `com.apple.mobile.diagnostics_relay.shim.remote` のポートへ接続する。
4. `RSDCheckin` → `StartService` の応答を確認する。この成功試験は **plain check-in（EscrowBagなし）**。OSキーを付けた試験では、その後に接続が閉じたため、成功した方式と混同しない。
5. 長さ付きplistで、以下のどちらかの読み取り要求を送る。

```json
{"Request":"GasGauge"}
```

```json
{"Request":"IORegistry","EntryClass":"IOPMPowerSource"}
```

6. `Status == "Success"` を確認し、`Diagnostics` 以下を調べる。許可した数値項目名だけを出力する。終了時にソケットとOSトンネルのassertionを解放する。

実装: [independent_diagnostics.py](../scripts/research/independent_diagnostics.py) の `read_only_diagnostic_query()` / `run()`、[native_tunnel.c](../scripts/research/native_tunnel.c)、[remote_wire.py](../scripts/research/remote_wire.py)。pymobiledevice3 / libimobiledevice のライブラリをインポート・実行・リンクせず、CとPython標準ライブラリで要求を送っている。トンネルと既存の信頼はAppleのOSサービスを使うため、OSから独立した通信方式ではない。

## 再現コマンド

Macリポジトリのルートで実行する。`<paired-device-UDID>` は既存ペアリング済み端末の値に置き換える。端末のアドレスやキーをソースに書かない。

```sh
mkdir -p Build/research
xcrun clang -fblocks -Wall -Wextra -Werror scripts/research/native_tunnel.c -o Build/research/native_tunnel
python3 -I -B scripts/research/test_independent_diagnostics.py

# 前後の確認に使う。Xcodeは状態確認・Cのビルド用で、Pythonの取得処理は呼び出さない。
xcrun devicectl device info lockState --device '<paired-device-UDID>' --timeout 15

python3 -I -B scripts/research/independent_diagnostics.py \
  --udid '<paired-device-UDID>' --probe gas-gauge --checkin plain

python3 -I -B scripts/research/independent_diagnostics.py \
  --udid '<paired-device-UDID>' --probe power-registry --checkin plain

xcrun devicectl device info lockState --device '<paired-device-UDID>' --timeout 15
```

成功時は `live_battery_query` に `status: "Success"` と `available_metrics` が出る。必ず `daily_analytics_acquired: false` と表示する。空の項目リストだけで有用なバッテリー値が取得できたと扱わない。

## 制限と次の検証

- **現在の診断スナップショット**であり、日次・週次のAnalyticsファイル、過去の履歴、Watchのログではない。Watchの情報を同じ要求で読めることは未確認。
- 成功したのは再ロック後数分以内。長時間ロック中の継続取得は未確認。先の試験では長いロック時間の後、OSのトンネル作成自体が1016で拒否されている。常時・無人で取得できるとは約束しない。
- Developer Modeオフ、iPad、Windowsのユーザー空間トンネル、クリーンな初回設定、別OSバージョンでは未検証。Windowsも同じ診断要求を検討できるが、Mac用Cヘルパーをそのまま移植できるわけではない。
- 取得した容量値の単位・意味・安定性を日次ログと照合してから、将来の別記録方式を検討する。既存のAnalytics記録と混ぜない。
- パスコード、OSペアリング、保護設定は変更しない。バックアップとiPhoneミラーリングは使っていない。日次ログの取得失敗を成功扱いにしない。

全体の比較結果: [LOCKED_ANALYTICS_RESEARCH.md](LOCKED_ANALYTICS_RESEARCH.md)。要求形式の参照元: [libimobiledevice diagnostics_relay.c](https://github.com/libimobiledevice/libimobiledevice/blob/master/src/diagnostics_relay.c)、[pymobiledevice3 RSDCheckin](https://github.com/doronz88/pymobiledevice3/blob/v11.19.1/pymobiledevice3/remote/remote_service_discovery.py)。参照したプロトコルと実装のライセンスを区別し、上流の実装を取り込む場合は改めてライセンスを確認する。
