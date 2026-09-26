# MochiLog Mac 0.2.3 Beta

Mac now checks live wireless diagnostic access before showing the MochiLog pairing QR. An OS-paired device can proceed without repeating setup; if OS pairing is later lost, the app keeps its MochiLog registration and guides reconnection. Initial setup offers wireless pairing with Developer Mode or USB trust without it. On an iPhone 17, analytics logs remained accessible wirelessly after Developer Mode was turned off. USB setup on a never-paired device has not yet been verified end to end and is accepted only after live wireless access succeeds.

Macが無線で診断ログに接続できたことを確認してから、MochiLogのペアリング用QRを表示します。OSペアリング済みなら初回操作を省け、後で接続が切れてもMochiLogの登録を保持して復旧を案内します。初回設定はデベロッパモードを使う無線方式と、使わないUSB方式を選べます。iPhone 17実機では、デベロッパモードをオフにした後も無線で解析ログを読めました。完全に未ペアリングの端末でUSBから始める通し試験は未実施で、無線接続の実測確認を通過した場合だけQRを使えるようにしています。
