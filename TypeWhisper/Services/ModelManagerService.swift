import Foundation
import Combine
import TypeWhisperPluginSDK

@MainActor
final class ModelManagerService: ObservableObject {
    @Published private(set) var modelStatuses: [String: ModelStatus] = [:]
    @Published private(set) var selectedEngine: EngineType
    @Published private(set) var selectedModelId: String?

    /// Whether the currently selected main engine is a cloud/plugin engine
    var isCloudEngineSelected: Bool {
        guard let selectedId = selectedModelId else { return false }
        return CloudProvider.isCloudModel(selectedId)
    }
    @Published private(set) var activeEngine: (any TranscriptionEngine)?

    private let whisperEngine = WhisperEngine()
    private let parakeetEngine = ParakeetEngine()
    private let _speechAnalyzerEngine: (any TranscriptionEngine)?

    private let engineKey = UserDefaultsKeys.selectedEngine
    private let modelKey = UserDefaultsKeys.selectedModelId
    private let loadedModelsKey = UserDefaultsKeys.loadedModelIds

    init() {
        if #available(macOS 26, *) {
            _speechAnalyzerEngine = SpeechAnalyzerEngine()
        } else {
            _speechAnalyzerEngine = nil
        }

        let savedEngine = UserDefaults.standard.string(forKey: engineKey)
            .flatMap { EngineType(rawValue: $0) } ?? .whisper
        self.selectedEngine = savedEngine
        self.selectedModelId = UserDefaults.standard.string(forKey: modelKey)

        // Initialize all models as not downloaded
        for model in ModelInfo.allModels {
            modelStatuses[model.id] = .notDownloaded
        }
    }

    var currentEngine: (any TranscriptionEngine)? {
        activeEngine
    }

    var isEngineLoaded: Bool {
        activeEngine != nil
    }

    func engine(for type: EngineType) -> any TranscriptionEngine {
        switch type {
        case .whisper: return whisperEngine
        case .parakeet: return parakeetEngine
        case .speechAnalyzer: return _speechAnalyzerEngine ?? whisperEngine
        }
    }

    func selectEngine(_ engine: EngineType) {
        selectedEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: engineKey)
    }

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
        UserDefaults.standard.set(modelId, forKey: modelKey)

        // Check if this is a plugin engine model (format: "providerId:modelId")
        if CloudProvider.isCloudModel(modelId) {
            let (providerId, pluginModelId) = CloudProvider.parse(modelId)
            if let plugin = PluginManager.shared.transcriptionEngine(for: providerId) {
                plugin.selectModel(pluginModelId)
                // Don't set activeEngine for plugins - they're resolved on-demand
                return
            }
        }

        if let model = ModelInfo.allModels.first(where: { $0.id == modelId }) {
            let eng = engine(for: model.engineType)
            guard eng.isModelLoaded else { return }
            activeEngine = eng
            selectEngine(model.engineType)
        }
    }

    func downloadAndLoadModel(_ model: ModelInfo) async {
        let engine = engine(for: model.engineType)

        modelStatuses[model.id] = .downloading(progress: 0)

        // Listen for phase changes from WhisperKit (loading -> prewarming)
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onPhaseChange = { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.modelStatuses[model.id] = .loading(phase: phase)
                }
            }
        }

        do {
            try await engine.loadModel(model) { [weak self] progress, speed in
                Task { @MainActor [weak self] in
                    if progress >= 0.80 {
                        self?.modelStatuses[model.id] = .loading()
                    } else {
                        self?.modelStatuses[model.id] = .downloading(progress: progress, bytesPerSecond: speed)
                    }
                }
            }

            modelStatuses[model.id] = .ready
            (engine as? WhisperEngine)?.onPhaseChange = nil
            activeEngine = engine
            selectEngine(model.engineType)
            selectModel(model.id)
            addToLoadedModels(model.id, engineType: model.engineType)
        } catch {
            modelStatuses[model.id] = .error(error.localizedDescription)
        }
    }

    func loadAllSavedModels() async {
        // Restore selected plugin engine model
        if let selectedId = selectedModelId, CloudProvider.isCloudModel(selectedId) {
            let (providerId, pluginModelId) = CloudProvider.parse(selectedId)
            if let plugin = PluginManager.shared.transcriptionEngine(for: providerId), plugin.isConfigured {
                plugin.selectModel(pluginModelId)
            }
        }

        var modelIds = UserDefaults.standard.stringArray(forKey: loadedModelsKey) ?? []

        // Migration: if loadedModelIds is empty but selectedModelId exists, seed from it
        if modelIds.isEmpty, let selectedId = selectedModelId {
            modelIds = [selectedId]
            UserDefaults.standard.set(modelIds, forKey: loadedModelsKey)
        }

        let modelsToLoad = modelIds.compactMap { id in
            ModelInfo.allModels.first(where: { $0.id == id })
        }

        if !modelsToLoad.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for model in modelsToLoad {
                    group.addTask {
                        await self.loadSingleModel(model)
                    }
                }
            }
        }

        // Set activeEngine to the selected engine
        if let selectedId = selectedModelId,
           let selectedModel = ModelInfo.allModels.first(where: { $0.id == selectedId }) {
            let eng = engine(for: selectedModel.engineType)
            if eng.isModelLoaded {
                activeEngine = eng
            }
        }
    }

    private func loadSingleModel(_ model: ModelInfo) async {
        let engine = engine(for: model.engineType)

        // Already loaded
        if engine.isModelLoaded {
            modelStatuses[model.id] = .ready
            return
        }

        modelStatuses[model.id] = .downloading(progress: 0)

        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onPhaseChange = { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.modelStatuses[model.id] = .loading(phase: phase)
                }
            }
        }

        do {
            try await engine.loadModel(model) { [weak self] progress, speed in
                Task { @MainActor [weak self] in
                    if progress >= 0.80 {
                        self?.modelStatuses[model.id] = .loading()
                    } else {
                        self?.modelStatuses[model.id] = .downloading(progress: progress, bytesPerSecond: speed)
                    }
                }
            }
            modelStatuses[model.id] = .ready
            // Clear phase callback so WhisperKit state changes during transcription
            // don't reset the model status from .ready back to .loading
            (engine as? WhisperEngine)?.onPhaseChange = nil
        } catch {
            modelStatuses[model.id] = .error(error.localizedDescription)
            removeFromLoadedModels(model.id)
        }
    }

    func deleteModel(_ model: ModelInfo) {
        let engine = engine(for: model.engineType)
        engine.unloadModel()

        // Delete model files from disk
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.deleteModelFiles(for: model)
        }

        modelStatuses[model.id] = .notDownloaded
        removeFromLoadedModels(model.id)

        if selectedModelId == model.id {
            // Fall back to another loaded engine
            if let fallback = findLoadedFallback(excluding: model.engineType) {
                selectEngine(fallback.engineType)
                selectModel(fallback.id)
                activeEngine = self.engine(for: fallback.engineType)
            } else {
                selectedModelId = nil
                UserDefaults.standard.removeObject(forKey: modelKey)
                activeEngine = nil
            }
        }
    }

    private func findLoadedFallback(excluding: EngineType) -> ModelInfo? {
        let remainingIds = UserDefaults.standard.stringArray(forKey: loadedModelsKey) ?? []
        return remainingIds.compactMap { id in
            ModelInfo.allModels.first(where: { $0.id == id })
        }.first { $0.engineType != excluding && engine(for: $0.engineType).isModelLoaded }
    }

    private func addToLoadedModels(_ modelId: String, engineType: EngineType) {
        var ids = UserDefaults.standard.stringArray(forKey: loadedModelsKey) ?? []
        // Remove any existing model of the same engine type (only 1 per engine)
        let sameEngineIds = ModelInfo.allModels
            .filter { $0.engineType == engineType }
            .map(\.id)
        ids.removeAll { sameEngineIds.contains($0) }
        ids.append(modelId)
        UserDefaults.standard.set(ids, forKey: loadedModelsKey)
    }

    private func removeFromLoadedModels(_ modelId: String) {
        var ids = UserDefaults.standard.stringArray(forKey: loadedModelsKey) ?? []
        ids.removeAll { $0 == modelId }
        UserDefaults.standard.set(ids, forKey: loadedModelsKey)
    }

    /// Re-restore cloud model selection after plugins have been loaded.
    /// Called from ServiceContainer after scanAndLoadPlugins().
    func restoreCloudModelSelection() {
        guard let selectedId = selectedModelId, CloudProvider.isCloudModel(selectedId) else { return }
        let (providerId, pluginModelId) = CloudProvider.parse(selectedId)
        if let plugin = PluginManager.shared.transcriptionEngine(for: providerId), plugin.isConfigured {
            plugin.selectModel(pluginModelId)
        }
    }

    func status(for model: ModelInfo) -> ModelStatus {
        modelStatuses[model.id] ?? .notDownloaded
    }

    // MARK: - Plugin Engine Resolution

    /// Resolve which engine to use for transcription.
    /// For plugin engines (String IDs not matching EngineType), returns nil but the caller
    /// should use `transcribeWithPlugin()` instead.
    func resolveEngine(override engineOverrideId: String?, cloudModelOverride: String? = nil) -> (any TranscriptionEngine)? {
        guard let overrideId = engineOverrideId else { return activeEngine }

        // Try builtin engine first
        if let builtinType = EngineType(rawValue: overrideId) {
            return engine(for: builtinType)
        }

        // Plugin engine - return nil (caller should use transcribeWithPlugin)
        return nil
    }

    /// Check if an engine override ID refers to a plugin engine
    func isPluginEngine(_ engineId: String) -> Bool {
        EngineType(rawValue: engineId) == nil
    }

    /// Resolve the display name for the current or overridden model
    func resolvedModelDisplayName(engineOverrideId: String? = nil, cloudModelOverride: String? = nil) -> String? {
        if let overrideId = engineOverrideId {
            // Builtin engine
            if let builtinType = EngineType(rawValue: overrideId) {
                return ModelInfo.models(for: builtinType).first(where: { status(for: $0) == .ready })?.displayName
            }
            // Plugin engine
            if let plugin = PluginManager.shared.transcriptionEngine(for: overrideId) {
                if let modelId = cloudModelOverride,
                   let model = plugin.transcriptionModels.first(where: { $0.id == modelId }) {
                    return model.displayName
                }
                if let selectedId = plugin.selectedModelId,
                   let model = plugin.transcriptionModels.first(where: { $0.id == selectedId }) {
                    return model.displayName
                }
                return plugin.providerDisplayName
            }
            return nil
        }

        guard let selectedId = selectedModelId else { return nil }
        if CloudProvider.isCloudModel(selectedId) {
            let (providerId, modelId) = CloudProvider.parse(selectedId)
            if let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
               let model = plugin.transcriptionModels.first(where: { $0.id == modelId }) {
                return model.displayName
            }
        }
        return ModelInfo.allModels.first(where: { $0.id == selectedId })?.displayName
    }

    // MARK: - Transcription

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
        let effectiveOverrideId = engineOverrideId

        // Check if this is a plugin engine
        if let overrideId = effectiveOverrideId, isPluginEngine(overrideId) {
            return try await transcribeWithPlugin(
                providerId: overrideId,
                audioSamples: audioSamples,
                language: language,
                translate: task == .translate,
                prompt: prompt,
                cloudModelOverride: cloudModelOverride
            )
        }

        // Also check if the selected model is a plugin engine (no override)
        if effectiveOverrideId == nil,
           let selectedId = selectedModelId,
           CloudProvider.isCloudModel(selectedId) {
            let (providerId, _) = CloudProvider.parse(selectedId)
            if isPluginEngine(providerId) {
                return try await transcribeWithPlugin(
                    providerId: providerId,
                    audioSamples: audioSamples,
                    language: language,
                    translate: task == .translate,
                    prompt: prompt,
                    cloudModelOverride: cloudModelOverride
                )
            }
        }

        // Builtin engine
        guard let engine = resolveEngine(override: effectiveOverrideId, cloudModelOverride: cloudModelOverride) else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        return try await engine.transcribe(
            audioSamples: audioSamples,
            language: language,
            task: task,
            prompt: prompt
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        let effectiveOverrideId = engineOverrideId

        // Plugin engines don't support streaming - fall back to batch
        if let overrideId = effectiveOverrideId, isPluginEngine(overrideId) {
            return try await transcribe(
                audioSamples: audioSamples,
                language: language,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride,
                prompt: prompt
            )
        }

        if effectiveOverrideId == nil,
           let selectedId = selectedModelId,
           CloudProvider.isCloudModel(selectedId) {
            let (providerId, _) = CloudProvider.parse(selectedId)
            if isPluginEngine(providerId) {
                return try await transcribe(
                    audioSamples: audioSamples,
                    language: language,
                    task: task,
                    engineOverrideId: nil,
                    cloudModelOverride: cloudModelOverride,
                    prompt: prompt
                )
            }
        }

        guard let engine = resolveEngine(override: effectiveOverrideId, cloudModelOverride: cloudModelOverride) else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        return try await engine.transcribe(
            audioSamples: audioSamples,
            language: language,
            task: task,
            prompt: prompt,
            onProgress: onProgress
        )
    }

    // MARK: - Plugin Transcription

    private func transcribeWithPlugin(
        providerId: String,
        audioSamples: [Float],
        language: String?,
        translate: Bool,
        prompt: String?,
        cloudModelOverride: String?
    ) async throws -> TranscriptionResult {
        guard let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
              plugin.isConfigured else {
            // Fall back to active local engine
            guard let engine = activeEngine, engine.isModelLoaded else {
                throw TranscriptionEngineError.modelNotLoaded
            }
            return try await engine.transcribe(
                audioSamples: audioSamples,
                language: language,
                task: translate ? .translate : .transcribe,
                prompt: prompt
            )
        }

        if let modelId = cloudModelOverride {
            plugin.selectModel(modelId)
        } else if plugin.selectedModelId == nil,
                  let firstModel = plugin.transcriptionModels.first {
            plugin.selectModel(firstModel.id)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let wavData = WavEncoder.encode(audioSamples)
        let audioDuration = Double(audioSamples.count) / 16000.0

        let audio = AudioData(
            samples: audioSamples,
            wavData: wavData,
            duration: audioDuration
        )

        let result = try await plugin.transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: []
        )
    }
}
