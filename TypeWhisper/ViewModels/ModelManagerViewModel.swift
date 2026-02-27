import Foundation
import Combine
import TypeWhisperPluginSDK

@MainActor
final class ModelManagerViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: ModelManagerViewModel?
    static var shared: ModelManagerViewModel {
        guard let instance = _shared else {
            fatalError("ModelManagerViewModel not initialized")
        }
        return instance
    }

    @Published var selectedEngine: EngineType
    @Published var models: [ModelInfo] = []
    @Published var modelStatuses: [String: ModelStatus] = [:]
    @Published var selectedModelId: String?

    private let modelManager: ModelManagerService
    private var cancellables = Set<AnyCancellable>()

    init(modelManager: ModelManagerService) {
        self.modelManager = modelManager
        self.selectedModelId = modelManager.selectedModelId
        self.selectedEngine = modelManager.selectedEngine
        self.models = ModelInfo.models(for: modelManager.selectedEngine)
        self.modelStatuses = modelManager.modelStatuses

        modelManager.$selectedEngine
            .dropFirst()
            .sink { [weak self] engine in
                DispatchQueue.main.async {
                    self?.selectedEngine = engine
                    self?.models = ModelInfo.models(for: engine)
                }
            }
            .store(in: &cancellables)

        modelManager.$modelStatuses
            .dropFirst()
            .sink { [weak self] statuses in
                DispatchQueue.main.async {
                    self?.modelStatuses = statuses
                }
            }
            .store(in: &cancellables)

        modelManager.$selectedModelId
            .dropFirst()
            .sink { [weak self] modelId in
                DispatchQueue.main.async {
                    self?.selectedModelId = modelId
                }
            }
            .store(in: &cancellables)

    }

    /// Call after PluginManager.shared is set to forward plugin state changes to the UI
    func observePluginManager() {
        PluginManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func selectEngine(_ engine: EngineType) {
        modelManager.selectEngine(engine)
        models = ModelInfo.models(for: engine)
    }

    func downloadModel(_ model: ModelInfo) {
        Task {
            await modelManager.downloadAndLoadModel(model)
        }
    }

    func deleteModel(_ model: ModelInfo) {
        modelManager.deleteModel(model)
    }

    func status(for model: ModelInfo) -> ModelStatus {
        modelStatuses[model.id] ?? .notDownloaded
    }

    var isModelReady: Bool {
        if modelManager.activeEngine?.isModelLoaded == true {
            return true
        }
        // Cloud models don't use activeEngine - check if plugin is configured
        if let selectedId = selectedModelId, CloudProvider.isCloudModel(selectedId) {
            let (providerId, _) = CloudProvider.parse(selectedId)
            return PluginManager.shared.transcriptionEngine(for: providerId)?.isConfigured ?? false
        }
        return false
    }

    var readyModels: [ModelInfo] {
        ModelInfo.allModels.filter { modelStatuses[$0.id]?.isReady == true }
    }

    func selectDefaultModel(_ modelId: String) {
        modelManager.selectModel(modelId)
    }

    var activeModelName: String? {
        guard let modelId = selectedModelId else { return nil }
        if CloudProvider.isCloudModel(modelId) {
            let (providerId, pluginModelId) = CloudProvider.parse(modelId)
            if let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
               let model = plugin.transcriptionModels.first(where: { $0.id == pluginModelId }) {
                return model.displayName
            }
        }
        return ModelInfo.allModels.first { $0.id == modelId }?.displayName
    }

    var activeEngineName: String? {
        guard let modelId = selectedModelId else { return nil }
        if CloudProvider.isCloudModel(modelId) {
            let (providerId, _) = CloudProvider.parse(modelId)
            if let plugin = PluginManager.shared.transcriptionEngine(for: providerId) {
                return plugin.providerDisplayName
            }
        }
        if let model = ModelInfo.allModels.first(where: { $0.id == modelId }) {
            return model.engineType.displayName
        }
        return nil
    }

    // MARK: - Plugin Transcription Engines

    var pluginTranscriptionEngines: [TranscriptionEnginePlugin] {
        PluginManager.shared.transcriptionEngines
    }

    var configuredPluginEngines: [TranscriptionEnginePlugin] {
        pluginTranscriptionEngines.filter { $0.isConfigured }
    }

    func selectPluginModel(_ modelId: String, providerId: String) {
        let fullId = CloudProvider.fullId(provider: providerId, model: modelId)
        modelManager.selectModel(fullId)
    }

    func selectedPluginModelId(for providerId: String) -> String? {
        if let selectedId = modelManager.selectedModelId,
           CloudProvider.isCloudModel(selectedId) {
            let (provider, model) = CloudProvider.parse(selectedId)
            if provider == providerId {
                return model
            }
        }
        return PluginManager.shared.transcriptionEngine(for: providerId)?.selectedModelId
    }
}
