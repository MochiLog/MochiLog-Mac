import SwiftUI

struct LiveBatteryCard: View {
  let snapshot: LiveBatterySnapshot?
  let failed: Bool
  let busy: Bool
  let receive: () -> Void
  let send: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(MacTransferL10n.text("live_title"), systemImage: "battery.100percent")
          .font(.headline)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], alignment: .leading, spacing: 12) {
        ForEach(["CycleCount", "DesignCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity", "FullChargeCapacity", "CurrentCapacity"], id: \.self) { key in
          VStack(alignment: .leading, spacing: 4) {
            Text(MacTransferL10n.text("live_" + key)).font(.caption).foregroundStyle(.secondary)
            Text(snapshot?.values[key].map { value in
              value.formatted() + (key == "CycleCount" ? "" : key == "CurrentCapacity" ? "%" : " mAh")
            } ?? MacTransferL10n.text("live_missing"))
            .font(.title3.weight(.semibold)).monospacedDigit()
          }
        }
      }
      if let snapshot, let date = ISO8601DateFormatter().date(from: snapshot.acquiredAt) {
        HStack {
          Text(MacTransferL10n.text("live_last"))
          Text(date, format: .dateTime.year().month().day().hour().minute().second())
        }.font(.caption).foregroundStyle(.secondary)
      }
      if failed { Label(MacTransferL10n.text("live_unavailable"), systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.orange) }
      HStack {
        Button(action: receive) { Label(MacTransferL10n.text("live_receive"), systemImage: "arrow.down.circle") }
        Button(action: send) { Label(MacTransferL10n.text("live_send"), systemImage: "paperplane") }
      }.disabled(busy)
      Text(MacTransferL10n.text("live_note")).font(.caption).foregroundStyle(.secondary)
    }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
  }
}
