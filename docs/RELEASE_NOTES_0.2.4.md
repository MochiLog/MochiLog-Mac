# MochiLog Mac 0.2.4 Beta

Mac now advertises its reachable local addresses so iPhone and iPad can connect even when Bonjour's service endpoint stalls. The listener uses a stable port. If Tailscale is active, a separate direct receiver offers an optional route without multicast discovery; devices without Tailscale continue to use the local network. Connection diagnostics now use the device's local time zone.

Macが接続可能なローカルアドレスを通知するようになり、Bonjourの接続先で通信が止まる場合もiPhone・iPadから接続できるよう改善しました。待受ポートを固定し、Tailscaleが有効な場合はマルチキャスト検出を使わない専用の受信経路も利用できます。Tailscaleを使わない端末は従来どおりローカルネットワークを使用します。接続診断の時刻は端末の標準時で表示します。
