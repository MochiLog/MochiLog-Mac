# MochiLog Mac 0.2.13 Beta

## 日本語

スマホアプリからの受信確認、重複判定、診断情報を含む転送要求全体を暗号化しました。要求の有効期限と再送防止情報を保存し、アプリ再起動後の再送や新方式から旧方式への戻りを防ぎます。未認証接続の数と待ち時間にも上限を設けました。

旧版のiPhone・iPadアプリは、更新するまで既存のペアリングのまま利用できます。旧方式を検出するとTestFlightまたはApp Storeでの更新を案内します。ログの解析と記録は引き続きスマホ側で行います。

## English

The full transfer request, including acknowledgements, duplicate checks, and diagnostics, is now encrypted. Request expiry and persistent replay protection reject repeated requests after an app restart and prevent a connection upgraded to the new protocol from silently falling back. Unauthenticated connections are also bounded by count and time.

Older iPhone and iPad builds can keep their existing pairing until updated. The Mac prompts for a TestFlight or App Store update when it detects the previous protocol. Parsing and record storage remain on the mobile app.
