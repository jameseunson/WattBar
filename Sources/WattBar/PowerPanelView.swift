import Charts
import SwiftUI

struct PowerPanelView: View {
    @Bindable var monitor: PowerMonitor
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.isAvailable {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(monitor.statusText)
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let average = monitor.averageWatts, let peak = monitor.peakWatts {
                        Text(String(format: "Last hour: avg %.1f W · peak %.1f W", average, peak))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    thermalLine
                }

                if monitor.chartPoints.count > 1 {
                    sparkline
                }

                readingSection("Components", readings: monitor.components)
                appSection
                readingSection("Power Source", readings: monitor.sources)
            } else {
                Label("Power sensors unavailable on this Mac", systemImage: "bolt.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Picker("Update Every", selection: $monitor.updateInterval) {
                ForEach(PowerMonitor.intervalOptions, id: \.self) { interval in
                    Text(interval < 1
                        ? String(format: "%.1fs", interval)
                        : String(format: "%.0fs", interval))
                    .tag(interval)
                }
            }
            .font(.callout)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }

            Button("Quit WattBar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .onAppear { monitor.isPanelVisible = true }
        .onDisappear { monitor.isPanelVisible = false }
    }

    private var sparkline: some View {
        Chart(monitor.chartPoints) { point in
            AreaMark(
                x: .value("Minutes Ago", point.minutesAgo),
                y: .value("Watts", point.watts)
            )
            .opacity(0.15)
            LineMark(
                x: .value("Minutes Ago", point.minutesAgo),
                y: .value("Watts", point.watts)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: -60...0)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
        .accessibilityLabel("System power over the last hour")
    }

    private var thermalLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(thermalColor)
                .frame(width: 7, height: 7)
            Text("Thermal pressure: \(thermalLabel)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }

    @ViewBuilder
    private var appSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps (Estimated)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !monitor.appReadings.isEmpty {
                readingGrid(monitor.appReadings)
            } else if monitor.hasAppSample {
                Text("No measurable app draw")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Estimating…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func readingSection(_ title: String, readings: [PowerMonitor.Reading]) -> some View {
        if !readings.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                readingGrid(readings)
            }
        }
    }

    private static let rowHelp: [String: String] = [
        "_other": """
        CPU time WattBar can't attribute to a specific app:
        • Privileged system processes (Spotlight indexing, WindowServer, \
        security daemons) — macOS doesn't let unprivileged apps read their usage.
        • Processes that started and exited between two updates. A shorter \
        update interval captures more of these.
        • Kernel work.
        """,
        "_rest": """
        Power drawn outside the SoC's measured components: display, SSD, \
        wifi/bluetooth, speakers, fans, and power-conversion losses. \
        Computed as the system total minus CPU, GPU, Neural Engine, and Memory.
        """,
    ]

    private func readingGrid(_ readings: [PowerMonitor.Reading]) -> some View {
        let hasDetail = readings.contains { $0.detail != nil }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(readings) { reading in
                GridRow {
                    rowLabel(reading)
                    if hasDetail {
                        Text(reading.detail ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                    Text(String(format: reading.watts < 0.095 ? "%.2f W" : "%.1f W", reading.watts))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
    }

    private func rowLabel(_ reading: PowerMonitor.Reading) -> some View {
        HStack(spacing: 4) {
            Text(reading.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let help = Self.rowHelp[reading.id] {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
