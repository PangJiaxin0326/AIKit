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

struct AssistantInputBar: View {
    @Binding var text: String

    let focused: FocusState<Bool>.Binding
    let activity: OrchestratorActivity
    let voiceLevel: Double
    let isRecording: Bool
    let isVoiceTranscribing: Bool
    let voiceError: String?
    let horizontalPadding: CGFloat
    let onSubmit: () -> Void
    let onStartVoiceRecording: () -> Void
    let onFinishVoiceRecording: () -> Void
    let onCancelCurrentWork: () -> Void
    let onDismissFailure: () -> Void
    let onTextChanged: () -> Void
    let onClearVoiceError: () -> Void

    private var trimmedTextIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            statusField
                .padding(.leading, horizontalPadding)
            actionButton
                .padding(.trailing, horizontalPadding)
        }
    }

    @ViewBuilder
    private var statusField: some View {
        if isRecording {
            VoiceWaveformView(level: voiceLevel)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isVoiceTranscribing {
            statusRow(
                systemImage: nil,
                text: AIKitUILocalization.string("Transcribing"),
                showsProgress: true
            )
        } else if activity.isBusy {
            statusRow(systemImage: nil, text: activity.aiKitLocalizedStatusText, showsProgress: true)
        } else if let voiceError {
            statusRow(
                systemImage: "exclamationmark.triangle.fill",
                text: voiceError,
                showsProgress: false
            )
            .onTapGesture(perform: onClearVoiceError)
        } else {
            TextField(
                activity.hasFailed
                    ? AIKitUILocalization.string("Add a clarification…")
                    : AIKitUILocalization.string("Ask the assistant…"),
                text: $text,
                prompt: activity.hasFailed
                    ? aiKitText("Add a clarification…")
                    : aiKitText("Ask the assistant…"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .focused(focused)
            .multilineTextAlignment(.leading)
            .submitLabel(.send)
            .onSubmit(onSubmit)
            .onChange(of: text) { _, _ in onTextChanged() }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(
        systemImage: String?,
        text: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.red)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRecording {
            Button(action: onFinishVoiceRecording) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Stop recording"))
        } else if isVoiceTranscribing {
            EmptyView()
        } else if activity.isBusy {
            Button(action: onCancelCurrentWork) {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Cancel"))
        } else if activity.hasFailed && trimmedTextIsEmpty {
            Button(action: onDismissFailure) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Dismiss"))
        } else if trimmedTextIsEmpty {
            Button(action: onStartVoiceRecording) {
                Image(systemName: "mic.fill")
                    .symbolRenderingMode(.monochrome)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.accentColor)
            .disabled(activity.isBusy || isVoiceTranscribing)
            .accessibilityLabel(aiKitText("Start recording"))
        } else {
            Button(action: onSubmit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(aiKitText("Send"))
        }
    }
}

struct VoiceWaveformView: View {
    let level: Double

    private let barCount = 36
    private let barSpacing: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let barWidth = max(
                    2,
                    (proxy.size.width - barSpacing * CGFloat(barCount - 1)) / CGFloat(barCount)
                )
                HStack(spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(
                                width: barWidth,
                                height: barHeight(index: index, date: timeline.date)
                            )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .center)
            .accessibilityLabel(aiKitText("Recording voice"))
        }
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        let clampedLevel = min(1, max(0.04, level))
        let midpoint = Double(barCount - 1) / 2
        let distance = abs(Double(index) - midpoint) / midpoint
        let envelope = 1 - distance * 0.48
        let phase = date.timeIntervalSinceReferenceDate * 8
        let ripple = 0.58 + 0.42 * sin(phase + Double(index) * 0.68)
        let height = 5 + 28 * clampedLevel * envelope * ripple
        return CGFloat(height)
    }
}

/// One entry in the detail panel's menus: a prominent title tightly paired
/// with its softened detail lines. The clear type contrast — bold primary
/// title over a lighter detail — is what makes each entry read as a heading
/// with its data, rather than a stack of look-alike lines.
