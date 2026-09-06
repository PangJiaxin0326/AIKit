import Foundation
import FoundationModels
import SwiftUI
import Observation
import AIToolKit
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import UICollection
#endif
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety
import MultiModalKit

struct AssistantRuntimeDetailContent: View {
    let snapshot: OrchestratorSnapshot?
    let activity: OrchestratorActivity
    @Binding var selectedMenu: ChatbotMenu
    @Binding var activityDisplay: OverlayActivityDisplay
    let maxContentHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(selection: $selectedMenu) {
                ForEach(ChatbotMenu.allCases) { menu in
                    Text(menu.title, bundle: .module).tag(menu)
                }
            } label: {
                aiKitText("Menu")
            }
            .pickerStyle(.segmented)

            menuContent
        }
        .animation(.snappy(duration: 0.2), value: selectedMenu)
        .animation(.snappy(duration: 0.18), value: activityDisplay)
    }

    @ViewBuilder
    private var menuContent: some View {
        if selectedMenu == .activity {
            activityContent
                .frame(maxHeight: maxContentHeight)
        } else {
            ScrollView {
                switch selectedMenu {
                case .context:
                    memoryContent
                case .tools:
                    toolsContent
                case .activity:
                    activityContent
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxContentHeight)
        }
    }

    private var memoryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot, !snapshot.contexts.isEmpty {
                ForEach(snapshot.contexts) { context in
                    OverlayDetailRow(title: context.displayName) {
                        Text(context.id.rawValue)
                            .monospaced()
                        if !context.systemPromptFragment.isEmpty {
                            Text(context.systemPromptFragment)
                                .lineLimit(3)
                        }
                        if !context.toolNames.isEmpty {
                            Text(context.toolNames.sorted().joined(separator: ", "))
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                OverlayEmptyState(
                    systemImage: "questionmark.bubble",
                    message: "No active memory"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot, !snapshot.availableTools.isEmpty {
                ForEach(snapshot.availableTools) { tool in
                    OverlayDetailRow(title: tool.name) {
                        Text(tool.description)
                            .lineLimit(3)
                    }
                }
            } else {
                OverlayEmptyState(
                    systemImage: "wrench.and.screwdriver",
                    message: "No tools available"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var activityContent: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 10) {
                activityHeader
                OverlayActivityStatsRow(metrics: activityMetrics(now: timeline.date))
                ScrollView {
                    activityRows(now: timeline.date)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var activityHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            if let destination = activityBackDestination {
                Button {
                    activityDisplay = destination
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
            .buttonStyle(.plain)
                .accessibilityLabel(aiKitText("Back"))
            }

            VStack(alignment: .leading, spacing: 3) {
                switch activityDisplay {
                case .tasks:
                    aiKitText("Tasks")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if activityTaskGroups.isEmpty {
                        aiKitText("No recent activity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(
                            localized: "\(activityTaskGroups.count) recent",
                            bundle: .module
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                case .task(let id):
                    if let task = activityTask(id: id) {
                        Text(task.instruction)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        activityStatusText(for: task)
                    } else {
                        aiKitText("Task unavailable")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                case .event(let taskID, let eventID):
                    if let event = activityEvent(taskID: taskID, eventID: eventID) {
                        Text(event.kind.rawDetailTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(event.kind.detailLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        aiKitText("Detail unavailable")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func activityRows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch activityDisplay {
            case .tasks:
                let tasks = activityTaskGroups
                if tasks.isEmpty {
                    OverlayEmptyState(systemImage: "clock", message: "No recent activity")
                } else {
                    ForEach(tasks) { task in
                        Button {
                            activityDisplay = .task(task.id)
                        } label: {
                            OverlayActivityTaskRow(task: task)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .task(let id):
                if let task = activityTask(id: id) {
                    if task.activities.isEmpty {
                        OverlayEmptyState(
                            systemImage: "list.bullet.rectangle",
                            message: "No task details"
                        )
                    } else {
                        ForEach(task.activities) { event in
                            Button {
                                activityDisplay = .event(taskID: task.id, eventID: event.id)
                            } label: {
                                OverlayActivityEventRow(event: event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    OverlayEmptyState(
                        systemImage: "clock.arrow.circlepath",
                        message: "Activity no longer available"
                    )
                }
            case .event(let taskID, let eventID):
                if let event = activityEvent(taskID: taskID, eventID: eventID) {
                    OverlayActivityRawPayload(event: event)
                } else {
                    OverlayEmptyState(
                        systemImage: "doc.text.magnifyingglass",
                        message: "Raw payload no longer available"
                    )
                }
            }
        }
    }

    private var activityTaskGroups: [OrchestratorTaskSnapshot] {
        var seen = Set<Int>()
        var groups: [OrchestratorTaskSnapshot] = []
        for task in activity.activeTasks.sorted(by: { $0.startedAt > $1.startedAt }) {
            if seen.insert(task.id).inserted {
                groups.append(task)
            }
        }
        for task in snapshot?.recentTasks ?? [] {
            if seen.insert(task.id).inserted {
                groups.append(task)
            }
        }
        return groups
    }

    private func activityTask(id: Int) -> OrchestratorTaskSnapshot? {
        activityTaskGroups.first { $0.id == id }
    }

    private func activityEvent(taskID: Int, eventID: UUID) -> UsageEvent? {
        activityTask(id: taskID)?.activities.first { $0.id == eventID }
    }

    private var activityBackDestination: OverlayActivityDisplay? {
        switch activityDisplay {
        case .tasks:
            return nil
        case .task:
            return .tasks
        case .event(let taskID, _):
            return .task(taskID)
        }
    }

    private func activityMetrics(now: Date) -> OverlayActivityMetrics {
        switch activityDisplay {
        case .tasks:
            return activityTaskGroups.reduce(.zero) { partial, task in
                OverlayActivityMetrics(
                    inputTokens: partial.inputTokens + task.usage.inputTokens,
                    outputTokens: partial.outputTokens + task.usage.outputTokens,
                    duration: partial.duration + task.duration(at: now)
                )
            }
        case .task(let id), .event(let id, _):
            guard let task = activityTask(id: id) else { return .zero }
            return OverlayActivityMetrics(
                inputTokens: task.usage.inputTokens,
                outputTokens: task.usage.outputTokens,
                duration: task.duration(at: now)
            )
        }
    }

    @ViewBuilder
    private func activityStatusText(for task: OrchestratorTaskSnapshot) -> some View {
        if let failure = task.failureReason {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if task.isRunning {
            Label(task.phase.activityLabel, systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        } else {
            Text(task.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct OverlayDetailRow<Detail: View>: View {
    let title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                detail
            }
            .font(.footnote)
            // Opaque primary, softened with a flat alpha — *not* the
            // hierarchical `.secondary` tier, whose vibrant blend over the
            // panel's translucent material can wash out to invisibility. This
            // keeps the detail clearly legible while staying subordinate to
            // the title.
            .foregroundStyle(.primary)
            .opacity(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OverlayActivityTaskRow: View {
    let task: OrchestratorTaskSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.instruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            Text(task.isRunning ? task.phase.activityLabel : AIKitUILocalization.string("Completed"))
                .font(.caption)
                .foregroundStyle(task.isRunning ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct OverlayActivityEventRow: View {
    let event: UsageEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.kind.detailSystemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.kind.detailLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(event.payloadText)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .opacity(0.75)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(event.kind.detailLabel)
    }
}

struct OverlayActivityRawPayload: View {
    let event: UsageEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(event.payloadText.isEmpty ? AIKitUILocalization.string("Empty payload") : event.payloadText)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OverlayActivityStatsRow: View {
    let metrics: OverlayActivityMetrics

    var body: some View {
        HStack(spacing: 12) {
            OverlayActivityStat(
                systemImage: "arrow.down.to.line.compact",
                title: "In",
                value: "\(metrics.inputTokens)"
            )
            OverlayActivityStat(
                systemImage: "arrow.up.to.line.compact",
                title: "Out",
                value: "\(metrics.outputTokens)"
            )
            OverlayActivityStat(
                systemImage: "timer",
                title: "Time",
                value: formattedActivityDuration(metrics.duration)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OverlayActivityStat: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.caption2.weight(.semibold))
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A quiet, centered placeholder for the detail panel's empty menus — a soft
/// glyph over a single line, so an empty state still feels considered.
struct OverlayEmptyState: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(LocalizedStringKey(message), bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

enum ChatbotMenu: CaseIterable, Identifiable {
    case context
    case tools
    case activity

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .context: "Memory"
        case .tools: "Tools"
        case .activity: "Activity"
        }
    }
}

enum OverlayActivityDisplay: Hashable {
    case tasks
    case task(Int)
    case event(taskID: Int, eventID: UUID)
}

struct OverlayActivityMetrics: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var duration: TimeInterval

    static let zero = OverlayActivityMetrics(
        inputTokens: 0, outputTokens: 0, duration: 0
    )
}

func formattedActivityDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    }
    return "\(seconds)s"
}

