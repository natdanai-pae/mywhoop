import SwiftUI
import GenieMax

@main
struct KiriTaraMaruApp: App {
  var body: some Scene {
    WindowGroup {
      DashboardView()
    }
  }
}

struct DashboardView: View {
  private let rrIntervals = [812.0, 798.0, 830.0, 805.0, 822.0, 816.0, 827.0]
  private let samples = [
    SleepSample(ts: 0, hr: 58, hrv: 72, motion: 0.04, resp: 14.5, temp: 33.1),
    SleepSample(ts: 60, hr: 57, hrv: 75, motion: 0.03, resp: 14.2, temp: 33.2),
    SleepSample(ts: 120, hr: 59, hrv: 69, motion: 0.05, resp: 14.4, temp: 33.0)
  ]

  var body: some View {
    let rmssd = HRV.metrics(rrIntervals)?.rmssd ?? 0
    let recoveryRemaining = DataReadiness.remaining(.recovery, nights: 3, days: 3, activities: 0)

    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("KiriTaraMaru")
            .font(.largeTitle.bold())
          Text("Open health analytics core")
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 12) {
          MetricRow(title: "RMSSD", value: "\(Int(rmssd.rounded())) ms")
          MetricRow(title: "Samples", value: "\(samples.count)")
          MetricRow(title: "Recovery", value: recoveryRemaining == 0 ? "Ready" : "\(recoveryRemaining) nights")
        }

        Spacer()
      }
      .padding(24)
      .navigationTitle("Today")
    }
  }
}

struct MetricRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.headline)
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}
