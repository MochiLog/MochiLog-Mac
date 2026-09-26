# MochiLog Mac 0.2.5 Beta

端末検索がタイムアウトした際にも、別のWi-Fi検索方式を試すよう改善しました。端末検索とログ収集の重複実行を防ぎ、検索タイムアウトの案内を修正しました。

Device discovery now tries the alternate Wi-Fi discovery method even when native discovery times out. Device discovery and log collection no longer run concurrently, and discovery timeout messages now describe the correct operation.

Tailscale経由で要求の到着が遅れたり分割されたりすると接続を閉じてしまう不具合を修正しました。

Fixed premature disconnects when requests arrive late or in multiple TCP segments over Tailscale.
