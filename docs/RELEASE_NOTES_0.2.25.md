# MochiLog Mac 0.2.25 (28) beta

## 日本語

複数端末への共有で、取得元の機種情報がないログを受信したiPadとして登録してしまう問題に対応しました。暗号化された転送前の確認に、元の端末の個体IDに対応する機種を添えます。スマホ4.0.0 (1052)以降が対応していることを確認してから、他端末のログを共有します。旧版スマホへの自分の端末のログ転送は維持し、ペアリングのやり直しは不要です。

転送済みの記録も、暗号化された共有確認で取得元の機種を確認できます。ログ本体を再送する必要はありません。

機種を確定できないログはスマホ側で選択を求めます。確認できる既存の誤登録はスマホ側で記録ID・日付・実測値を保って訂正します。取得元・受信先・機種の確認結果を動作ログへ残します。バッテリーログの解析は引き続きスマホ側だけで行います。

## English

Encrypted preflight offers now include the model of the originating physical device. This prevents an Analytics log without hardware model metadata from being recorded as the receiving device during cross-device sharing. Foreign logs are shared only with mobile 4.0.0 (1052) or later clients that advertise support. Older clients retain own-device transfers and existing pairing.

The encrypted consent policy also refreshes source models for already-delivered logs, so existing records can be corrected without retransferring their bodies.

Unknown sources require device selection on mobile. Verified incorrect existing records are repaired without changing record IDs, dates, or measurements. Activity logs record the source, recipient, and model. Battery log parsing remains on mobile.
