# Dependency audit — 6 September 2026

Scope: every direct and transitive Swift package dependency of AIKit, including the existing uncommitted dependency changes approved for inclusion. Review covered package distribution, module boundaries, public workflow contracts, cancellation and shared state, provider request/stream translation, platform availability, and tests. This is a source and build audit, not an assurance that every possible runtime defect is absent.

## Dependency graph and revisions

| Repository | Used for | Package dependencies | Audited revision |
| --- | --- | --- | --- |
| AIToolKit | Native Foundation Models profiles, tool helpers, guardrails | None | `417c8023f9d99a6e739dc686c577b62729e71f31` |
| MultiModalKit | Voice, recording, speech, permissions, media and vision | None after the existing tool extraction | `c8711adb6c3bea390fb1c21fd192f577857c50ad` |
| UICollection | General SwiftUI components; optional AIUICollection workflows | AIToolKit, same revision as AIKit | `6552495b008b2896e31f6054137de12bccb016dd` |
| VolcengineArkFoundationModels | Optional cloud provider and internal wire client | None | `f538c10caf8d0af848643049fcd67729eddc0f1b` |

There are four unique package dependencies and no additional external package dependencies. Apple SDK frameworks are platform dependencies, not vendored packages; their implementations were not audited. AIKit's core/runtime/safety layers remain independent of concrete cloud providers. The internal Ark wire target does not import FoundationModels or expose wire types through the public bridge.

The review used the installed Swift 6.4 / Apple OS 27 SDK interfaces for the actual native profile hooks, executor and generation-channel contracts. Relevant primary references: [WWDC26 Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/), [Foundation Models documentation](https://developer.apple.com/documentation/FoundationModels/), and [Swift 6.4 updates](https://developer.apple.com/swift/whats-new/). SDK declarations and compiler verification take precedence over illustrative examples.

## Findings and fixes

| Priority | Location | Before | After |
| --- | --- | --- | --- |
| High | UICollection login, onboarding and profile views | Used button/glass APIs unavailable on the declared visionOS platform. | Use supported prominent button styles and native visionOS glass backgrounds behind platform guards. |
| High | AIKit and UICollection `Package.swift` | Required sibling folders; GitHub consumers could not resolve the published graph in isolation. | GitHub dependencies pinned to the audited commits. `SWIFTPACKAGES_USE_LOCAL_DEPENDENCIES=1` explicitly selects sibling development. |
| High | Ark `Package.swift` | Explicitly required an ignored local-defaults source file absent from a clean checkout. | Local defaults excluded; the host supplies credentials through the public configuration initializer. Build output is ignored. |
| High | AIToolKit `WorkflowProfile.swift` | Substring validation could select `send` and `message` when only `send_message` was requested. | Structured selection requires exact case-insensitive names; text parsing matches complete identifiers. Documentation no longer recommends enabling every tool on invalid selection. |
| High | UICollection `AIViewWorkflow.swift` | Invalid selection expanded access to every finishing tool. Any tool error could trigger automatic replay. | Invalid selection ends the run; work executes once. Hosts retain responsibility for any explicitly safe retry. |
| High | UICollection runners and `AIViewCatalog.swift` | Runs sharing a catalog could reset and mix each other's results. | Catalog admission rejects overlap and is released after the admitted run finishes. Hook state uses compiler-checked `Mutex` storage. |
| High | MultiModalKit `SpeechSynthesizer.swift` | An old utterance callback or cancellation could finish or stop a replacement utterance. | Delegate completion and cancellation match the active utterance identity. Already-cancelled calls do not start playback. |
| High | MultiModalKit `AudioRecorder.swift` | Async starts could overlap or attach a recorder after stop/cancellation. | Admission covers permission and recorder creation; late completion stops its recorder and throws cancellation. |
| High | MultiModalKit `LiveSpeechSession.swift` | Reentrant or cancelled startup could activate capture later; the iOS 26 tap forwarded a reusable buffer. | Startup admission and post-suspension checks prevent late activation; the fallback transfers a copied buffer. Meter updates retain only the newest level. |
| High | Ark `SSEParser.swift` | Malformed JSON frames and streamed error envelopes disappeared, allowing partial output to look successful. | These frames throw a typed client error mapped to the provider taxonomy. Unknown JSON fields still decode. |
| High | Ark executor and `EventTranslator.swift` | Transport cancellation could return normally. | Partial usage is published, then cancellation propagates. |
| Medium | Ark `RequestBuilder.swift` | Empty successful tool output could be omitted, leaving a tool call without a matching result message. | Empty tool output retains its protocol message. |
| Medium | Ark `ArkClient.swift` | HTTP error response bodies were collected without a size limit, despite capped displayed excerpts. | Error-body capture is capped at 64 KiB while preserving HTTP status classification. |
| Medium | MultiModalKit `SpeechTranscription.swift` | The result child task started before opening the audio file; analyzer failure lacked explicit shutdown before child-task unwinding. | Open the file first and cancel/finalize the native analyzer on failure before unwinding. |
| Medium | UICollection section and progressive builders | Negative counts trapped in `prefix`; a step with no new result could re-emit the previous component. | Counts are clamped to zero; callbacks require a newly produced spec. Ordered selection also uses exact names. |
| Medium | AIToolKit `ParallelWorkflowProfile.swift` | A model response without the forced tool output reported success. | It reports failure unless the tool-output completion path was reached. |

Existing changes retained and reviewed include native `@SessionPropertyEntry` migration, forced/parallel workflow support, media-tool extraction, location permissions, iOS 27 audio APIs with an iOS 26 fallback, responsive section composition, and the Ark wire/bridge split. These are included in the dependency commits rather than discarded.

## Verification

- AIToolKit: 22 Swift Testing tests pass.
- MultiModalKit: 11 tests pass, including cancellation before permission/playback starts.
- UICollection: 5 tests pass, including exact ordered plans, negative limits, and catalog admission.
- Ark: 5 tests pass (including parameterized cases), covering SSE line endings, unknown keys, malformed/error frames, EOF usage, termination, and reserved request fields.
- AIKit: 163 tests pass. Added native-session regressions for malformed provider streams and empty tool outputs; existing tests cover provider translation, native workflows, guardrails, persistence, cancellation, and settlement.
- Platform builds: macOS 27 package builds; AIKit iOS 27 and visionOS 27; both UICollection products on iOS 27 and visionOS 27; MultiModalKit compiled targeting iOS 26 against the OS 27 SDK.
- Clean distribution check: an isolated AIKit source snapshot resolves all four pinned revisions directly from GitHub and runs the AIKit suite without sibling folders or the ignored provider configuration file.
- `git diff --check` passes. No credentials or generated build products were staged. The new tests use no network, real credentials, microphone, camera, or user Keychain. GitHub package resolution itself requires network access.

## Compatibility and limits

The stack requires the installed Swift 6.4 / Apple OS 27 SDK generation. MultiModalKit retains its iOS 26 deployment floor and its Swift 6.3 manifest requirement; the full AIKit stack requires OS 27. The existing extraction removes the old MultiModalKit tool exports; hosts using those exports must migrate to the separate MultiModalAITools package. Deprecated raw workflow property keys retain separate storage; use the native named session properties.

Exact revisions deliberately avoid silently taking future dependency changes. Updating a dependency requires updating the corresponding manifest pins together. Local override builds test local source instead of those revisions.

No live paid provider calls or physical microphone/camera/location-permission prompts were exercised. The iOS 26 check is an availability/build check, not execution on an iOS 26 device. Speech callback ownership and analyzer failure cleanup were reviewed and compiled; hardware behavior still needs host-app validation. Tests emitted sandbox-related CoreData notification diagnostics in the restricted local run; persistence assertions passed.
