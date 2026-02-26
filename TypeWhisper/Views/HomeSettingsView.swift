import SwiftUI
import Charts

struct HomeSettingsView: View {
    @ObservedObject private var viewModel = HomeViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        if viewModel.showSetupWizard {
            SetupWizardView()
                .frame(minWidth: 500, minHeight: 400)
        } else {
            dashboardView
        }
    }

    private var dashboardView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Time period picker
                HStack {
                    Text(String(localized: "Dashboard"))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Picker("", selection: $viewModel.selectedTimePeriod) {
                        ForEach(TimePeriod.allCases, id: \.self) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                // Permissions warning
                if dictation.needsMicPermission || dictation.needsAccessibilityPermission {
                    permissionsBanner
                }

                // Stats grid
                statsGrid

                // Activity chart
                chartSection

                // Run setup again
                HStack {
                    Spacer()
                    Button {
                        viewModel.resetSetupWizard()
                    } label: {
                        Label(String(localized: "Run setup again"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                #if DEBUG
                HStack(spacing: 8) {
                    Spacer()
                    Button("Seed Demo Data") {
                        let historyService = ServiceContainer.shared.historyService
                        historyService.seedDemoData()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .font(.caption)
                    Button("Clear All Data") {
                        let historyService = ServiceContainer.shared.historyService
                        historyService.clearAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
                #endif
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var statsGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCard(
                    title: String(localized: "Words"),
                    value: "\(viewModel.wordsCount)",
                    systemImage: "text.word.spacing"
                )
                StatCard(
                    title: String(localized: "Avg. WPM"),
                    value: viewModel.averageWPM,
                    systemImage: "speedometer"
                )
                StatCard(
                    title: String(localized: "Apps Used"),
                    value: "\(viewModel.appsUsed)",
                    systemImage: "app.badge"
                )
                StatCard(
                    title: String(localized: "Time Saved"),
                    value: viewModel.timeSaved,
                    systemImage: "clock.badge.checkmark"
                )
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Activity"))
                .font(.headline)

            if viewModel.chartData.isEmpty || viewModel.chartData.allSatisfy({ $0.wordCount == 0 }) {
                Text(String(localized: "No activity in this period."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart(viewModel.chartData) { point in
                    BarMark(
                        x: .value(String(localized: "Date"), point.date, unit: .day),
                        y: .value(String(localized: "Words"), point.wordCount)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: viewModel.selectedTimePeriod == .week ? 1 : 5)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var permissionsBanner: some View {
        VStack(spacing: 8) {
            if dictation.needsMicPermission {
                HStack {
                    Label(
                        String(localized: "Microphone access required"),
                        systemImage: "mic.slash"
                    )
                    Spacer()
                    Button(String(localized: "Grant Access")) {
                        dictation.requestMicPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        String(localized: "Accessibility access required"),
                        systemImage: "lock.shield"
                    )
                    Spacer()
                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .foregroundStyle(.red)
        .padding()
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
