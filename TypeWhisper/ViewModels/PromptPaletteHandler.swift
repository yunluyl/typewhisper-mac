import AppKit
import ApplicationServices
import Foundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "PromptPaletteHandler")

@MainActor
final class PromptPaletteHandler {
    private let promptPaletteController = PromptPaletteController()

    private struct PaletteContext {
        let text: String
        let selection: TextInsertionService.TextSelection?
        let focusedElement: AXUIElement?
        let activeApp: (name: String?, bundleId: String?, url: String?)
        let browserInfoTask: Task<(url: String?, title: String?), Never>?
    }
    private var paletteContext: PaletteContext?

    private let textInsertionService: TextInsertionService
    private let promptActionService: PromptActionService
    private let promptProcessingService: PromptProcessingService
    private let soundService: SoundService

    var onShowNotchFeedback: ((String, String, TimeInterval, Bool) -> Void)?
    var onShowError: ((String) -> Void)?
    var executeActionPlugin: ((any ActionPlugin, String, String,
        (name: String?, bundleId: String?, url: String?), String?, String?) async throws -> Void)?
    var getActionFeedback: (() -> (message: String?, icon: String?, duration: TimeInterval))?

    var isVisible: Bool { promptPaletteController.isVisible }

    init(
        textInsertionService: TextInsertionService,
        promptActionService: PromptActionService,
        promptProcessingService: PromptProcessingService,
        soundService: SoundService
    ) {
        self.textInsertionService = textInsertionService
        self.promptActionService = promptActionService
        self.promptProcessingService = promptProcessingService
        self.soundService = soundService
    }

    func hide() {
        promptPaletteController.hide()
    }

    func triggerSelection(currentState: DictationViewModel.State, soundFeedbackEnabled: Bool) {
        // Toggle behavior
        if promptPaletteController.isVisible {
            promptPaletteController.hide()
            return
        }
        guard currentState == .idle else { return }

        guard promptProcessingService.isCurrentProviderReady else {
            soundService.play(.error, enabled: soundFeedbackEnabled)
            onShowError?(String(localized: "noLLMProvider"))
            return
        }

        let actions = promptActionService.getEnabledActions()
        guard !actions.isEmpty else { return }

        // Capture active app BEFORE the palette steals focus
        let activeApp = textInsertionService.captureActiveApp()

        // Start resolving browser URL + title asynchronously
        var browserInfoTask: Task<(url: String?, title: String?), Never>?
        if let bundleId = activeApp.bundleId {
            let tis = textInsertionService
            browserInfoTask = Task {
                await tis.resolveBrowserInfo(bundleId: bundleId)
            }
        }

        // Try to get selected text (with element reference), fall back to clipboard
        let text: String
        var selection: TextInsertionService.TextSelection?
        var focusedElement: AXUIElement?
        if let sel = textInsertionService.getTextSelection() {
            text = sel.text
            selection = sel
            logger.info("[PromptPalette] Got selected text: \(text.prefix(80))")
        } else if let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty {
            text = clipboard
            focusedElement = textInsertionService.getFocusedTextElement()
            logger.info("[PromptPalette] No selection, using clipboard: \(text.prefix(80))")
        } else {
            logger.info("[PromptPalette] No text available, aborting")
            return
        }

        paletteContext = PaletteContext(
            text: text,
            selection: selection,
            focusedElement: focusedElement,
            activeApp: activeApp,
            browserInfoTask: browserInfoTask
        )

        promptPaletteController.show(actions: actions, sourceText: text) { [weak self] action in
            self?.processStandalonePrompt(action: action, soundFeedbackEnabled: soundFeedbackEnabled)
        }
    }

    private func processStandalonePrompt(action: PromptAction, soundFeedbackEnabled: Bool) {
        guard let ctx = paletteContext else { return }
        paletteContext = nil

        onShowNotchFeedback?(action.name + "...", "ellipsis.circle", 30, false)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await promptProcessingService.process(
                    prompt: action.prompt,
                    text: ctx.text,
                    providerOverride: action.providerType,
                    cloudModelOverride: action.cloudModel
                )
                guard !Task.isCancelled else { return }

                // Route to action plugin if configured
                if let actionPluginId = action.targetActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    let browserInfo = await ctx.browserInfoTask?.value
                    let resolvedUrl = browserInfo?.url ?? ctx.activeApp.url
                    let resolvedApp = (name: browserInfo?.title ?? ctx.activeApp.name,
                                       bundleId: ctx.activeApp.bundleId, url: resolvedUrl)
                    try await executeActionPlugin?(
                        actionPlugin, actionPluginId, result,
                        resolvedApp, ctx.text, nil
                    )
                    soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                    let feedback = getActionFeedback?() ?? (message: nil, icon: nil, duration: 3.5)
                    onShowNotchFeedback?(
                        feedback.0 ?? "Done",
                        feedback.1 ?? "checkmark.circle.fill",
                        feedback.2,
                        false
                    )
                    return
                }

                if let selection = ctx.selection {
                    logger.info("[PromptPalette] Replacing selection with result (\(result.count) chars): \(result.prefix(80))")
                    let replaced = textInsertionService.replaceSelectedText(in: selection, with: result)
                    logger.info("[PromptPalette] replaceSelectedText succeeded: \(replaced)")
                    if !replaced {
                        logger.info("[PromptPalette] Falling back to clipboard")
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(result, forType: .string)
                    }
                    soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                    onShowNotchFeedback?(
                        replaced ? String(localized: "Text replaced") : String(localized: "Copied to clipboard"),
                        replaced ? "checkmark.circle.fill" : "doc.on.clipboard.fill",
                        2.5,
                        false
                    )
                } else if let element = ctx.focusedElement {
                    let inserted = textInsertionService.insertTextAt(element: element, text: result)
                    if inserted {
                        soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                        onShowNotchFeedback?(String(localized: "Text inserted"), "checkmark.circle.fill", 2.5, false)
                    } else {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(result, forType: .string)
                        soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                        onShowNotchFeedback?(String(localized: "Copied to clipboard"), "doc.on.clipboard.fill", 2.5, false)
                    }
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result, forType: .string)
                    soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                    onShowNotchFeedback?(String(localized: "Copied to clipboard"), "doc.on.clipboard.fill", 2.5, false)
                }
            } catch {
                guard !Task.isCancelled else { return }
                soundService.play(.error, enabled: soundFeedbackEnabled)
                onShowNotchFeedback?(error.localizedDescription, "xmark.circle.fill", 2.5, true)
            }
        }
    }
}
