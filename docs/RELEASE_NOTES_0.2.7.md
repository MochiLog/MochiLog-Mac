# MochiLog Mac 0.2.7 Beta

## 日本語

MochiLog Macは、iOS/iPadOS 27の解析ログをiPhone・iPad版MochiLogへ渡すmacOS 27向けベータ版です。Macがログを収集・一時保存し、解析と記録は端末側で行います。署名・公証済みのDMGに必要な収集ツールを同梱しています。

- ロック解除中の端末を5分ごとに確認し、新しい解析ログを収集するようにしました。端末がロック中なら次回に再試行します。
- 無線で端末が見つからない場合の手動IP指定と、接続経路の診断を追加しました。Macが収集済みのログは、MochiLogを開いた端末へ暗号化して転送します。
- 端末ごとの接続状態を表示し、Mac側から個別にMochiLogペアリングを解除できるようにしました。解除は認証された接続を通じて相手側にも反映します。
- ペアリングと転送の確認を強化し、不完全な診断ファイルを転送キューに入れないようにしました。初回設定や解析ログが見つからない場合のガイドも改善しました。
- 同梱するPythonランタイムと依存パッケージのライセンス表示を充実させました。

**ベータ版の条件:** 新しい解析ログの収集には端末のロック解除とAppleの診断サービスに接続できるローカル無線環境が必要です。Tailscaleのモバイル通信経由ではMacが収集済みのログを転送できますが、端末内の新しい解析ログは収集できません。問題が起きた場合はアプリ内のサポート画面から診断情報を確認できます。

## English

MochiLog Mac is a macOS 27 beta companion that delivers iOS/iPadOS 27 analytics logs to MochiLog on iPhone and iPad. The Mac collects and temporarily queues files; the mobile app parses and records them. The signed and notarized DMG includes the collector and its dependencies.

- Checks unlocked devices every five minutes for new analytics logs. Locked devices are retried on a later check.
- Adds a manual device IP fallback and connection diagnostics when wireless discovery fails. Collected files are encrypted before transfer to an open MochiLog app.
- Shows each device's connection state and allows removing an individual MochiLog pairing from the Mac. Removal is relayed to the other side over an authenticated connection.
- Strengthens pairing and transfer confirmation, excludes incomplete diagnostic files from the queue, and improves setup and missing-log guidance.
- Expands the bundled Python runtime and dependency license notices.

**Beta requirements and limits:** Collecting new analytics logs requires an unlocked device and a local wireless route to Apple's diagnostic service. Tailscale over cellular can transfer files already collected by the Mac, but cannot collect new system analytics files from the device. The in-app support screen includes reviewable diagnostics for problems.
