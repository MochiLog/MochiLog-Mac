# 日本語

- 端末内取得へ既存のOSペアリングを引き継ぐ際、ホスト名の大文字・小文字の変換により認証に失敗する問題を修正しました。既存の信頼情報を使用し、再ペアリングは不要です。
- iPhoneとiPadの実機で、認証・バッテリー情報の取得・解析ログの読み取りを検証しています。

# English

- Fixed authentication failures when reusing an existing OS pairing for on-device collection. The original hostname spelling is now preserved when deriving the trusted host identifier. Existing pairings remain intact.
- Verified authentication, current battery data, and read-only analytics-file acquisition on physical iPhone and iPad devices.
