import Foundation
import Combine

@MainActor
final class Store: ObservableObject {

    static let shared = Store()

    @Published private(set) var sources: [Source] = []
    @Published private(set) var channelsBySource: [UUID: [Channel]] = [:]
    @Published var selectedSourceID: UUID?
    @Published private(set) var epgSources: [EPGSource] = []
    @Published private(set) var epgDatabase: EPGDatabase?
    @Published var settings: AppSettings = .default {
        didSet { persistSettings() }
    }

    @Published var isRefreshing = false
    @Published var epgRefreshing = false
    @Published var lastError: String?

    private let defaults = UserDefaults.standard
    private let sourcesKey = "msplayer.sources"
    private let channelsKey = "msplayer.channels"
    private let selectedKey = "msplayer.selectedSource"
    private let epgSourcesKey = "msplayer.epgSources"
    private let epgKey = "msplayer.epg"
    private let settingsKey = "msplayer.settings"

    private init() {
        load()
        seedDemoIfNeeded()
    }

    // MARK: - 当前列表

    var currentSource: Source? {
        guard let id = selectedSourceID else { return sources.first }
        return sources.first { $0.id == id } ?? sources.first
    }

    var currentChannels: [Channel] {
        guard let source = currentSource else { return [] }
        return channelsBySource[source.id] ?? []
    }

    var currentGroups: [ChannelGroup] {
        ChannelGrouping.groups(from: currentChannels)
    }

    func channels(for source: Source) -> [Channel] {
        channelsBySource[source.id] ?? []
    }

    func groups(for source: Source) -> [ChannelGroup] {
        ChannelGrouping.groups(from: channels(for: source))
    }

    func select(_ source: Source) {
        selectedSourceID = source.id
        persistSources()
    }

    // MARK: - 订阅管理

    func addRemoteSource(name: String, url: String) async throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.badURL }
        let text = try await HTTPService.fetchText(trimmed)
        let channels = PlaylistParser.parse(text)
        guard !channels.isEmpty else { throw StoreError.emptyPlaylist }

        var source = Source(name: name.isEmpty ? defaultName(for: trimmed) : name,
                            kind: .remote,
                            location: trimmed)
        source.count = channels.count
        source.updatedAt = Date()
        sources.append(source)
        channelsBySource[source.id] = channels
        selectedSourceID = source.id
        persistSources()
    }

    func addLocalSource(name: String, content: String, location: String) throws {
        let channels = PlaylistParser.parse(content)
        guard !channels.isEmpty else { throw StoreError.emptyPlaylist }
        var source = Source(name: name.isEmpty ? defaultName(for: location) : name,
                            kind: .local,
                            location: location)
        source.count = channels.count
        source.updatedAt = Date()
        sources.append(source)
        channelsBySource[source.id] = channels
        selectedSourceID = source.id
        persistSources()
    }

    func refresh(_ source: Source) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let text: String
            if source.kind == .builtin {
                guard let url = Bundle.main.url(forResource: "demo", withExtension: "m3u") else {
                    throw StoreError.emptyPlaylist
                }
                text = try String(contentsOf: url, encoding: .utf8)
            } else {
                text = try await HTTPService.fetchText(source.location)
            }
            let channels = PlaylistParser.parse(text)
            guard !channels.isEmpty else { throw StoreError.emptyPlaylist }
            apply(channels: channels, to: source.id)
        } catch {
            lastError = "刷新失败：\(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        for source in sources where source.kind == .remote {
            await refresh(source)
        }
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        channelsBySource.removeValue(forKey: source.id)
        if selectedSourceID == source.id {
            selectedSourceID = sources.first?.id
        }
        persistSources()
    }

    func rename(_ source: Source, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].name = name
        persistSources()
    }

    private func apply(channels: [Channel], to sourceID: UUID) {
        channelsBySource[sourceID] = channels
        if let index = sources.firstIndex(where: { $0.id == sourceID }) {
            sources[index].count = channels.count
            sources[index].updatedAt = Date()
        }
        persistSources()
    }

    // MARK: - EPG 订阅

    func addEPGSource(name: String, url: String) async throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.badURL }
        let database = try await EPGService.fetch(trimmed)
        guard database.totalPrograms > 0 else { throw StoreError.emptyEPG }

        var source = EPGSource(name: name.isEmpty ? defaultName(for: trimmed) : name, url: trimmed)
        source.updatedAt = Date()
        source.programCount = database.totalPrograms
        epgSources.append(source)
        merge(database)
        persistEPG()
    }

    func refreshEPG(_ source: EPGSource) async {
        epgRefreshing = true
        defer { epgRefreshing = false }
        do {
            let database = try await EPGService.fetch(source.url)
            guard database.totalPrograms > 0 else { throw StoreError.emptyEPG }
            if let index = epgSources.firstIndex(where: { $0.id == source.id }) {
                epgSources[index].updatedAt = Date()
                epgSources[index].programCount = database.totalPrograms
            }
            merge(database)
            persistEPG()
        } catch {
            lastError = "EPG 刷新失败：\(error.localizedDescription)"
        }
    }

    func refreshAllEPG() async {
        for source in epgSources {
            await refreshEPG(source)
        }
    }

    func removeEPG(_ source: EPGSource) {
        epgSources.removeAll { $0.id == source.id }
        if epgSources.isEmpty {
            epgDatabase = nil
        }
        persistEPG()
    }

    func clearEPG() {
        epgSources.removeAll()
        epgDatabase = nil
        persistEPG()
    }

    private func merge(_ incoming: EPGDatabase) {
        var base = epgDatabase ?? EPGDatabase()
        for (id, names) in incoming.channelNames {
            var merged = base.channelNames[id] ?? []
            for name in names where !merged.contains(name) { merged.append(name) }
            base.channelNames[id] = merged
        }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        for (id, programs) in incoming.programs {
            var list = base.programs[id] ?? []
            list.append(contentsOf: programs)
            var seen = Set<String>()
            list = list
                .filter { $0.stop > cutoff }
                .filter { seen.insert("\($0.start.timeIntervalSince1970)|\($0.title)").inserted }
                .sorted { $0.start < $1.start }
            base.programs[id] = Array(list.prefix(500))
        }
        epgDatabase = base
    }

    // MARK: - EPG 查询

    func programInfo(for channel: Channel, at date: Date = Date()) -> (now: EPGProgram?, next: EPGProgram?) {
        guard let database = epgDatabase,
              let key = EPGMatching.match(channel: channel, in: database) else {
            return (nil, nil)
        }
        return database.nowNext(channelID: key, at: date)
    }

    func upcomingPrograms(for channel: Channel, hours: Double = 12) -> [EPGProgram] {
        guard let database = epgDatabase,
              let key = EPGMatching.match(channel: channel, in: database),
              let list = database.programs[key] else {
            return []
        }
        let from = Date().addingTimeInterval(-3600)
        let to = Date().addingTimeInterval(hours * 3600)
        return list.filter { $0.stop > from && $0.start < to }
    }

    // MARK: - 持久化

    private func load() {
        if let data = defaults.data(forKey: settingsKey),
           let value = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = value
        }
        if let data = defaults.data(forKey: sourcesKey),
           let list = try? JSONDecoder().decode([Source].self, from: data) {
            sources = list
        }
        if let data = defaults.data(forKey: channelsKey),
           let stored = try? JSONDecoder().decode([String: [Channel]].self, from: data) {
            var map: [UUID: [Channel]] = [:]
            for (key, value) in stored {
                if let id = UUID(uuidString: key) { map[id] = value }
            }
            channelsBySource = map
        }
        if let data = defaults.data(forKey: selectedKey),
           let id = try? JSONDecoder().decode(UUID.self, from: data) {
            selectedSourceID = id
        }
        if selectedSourceID == nil { selectedSourceID = sources.first?.id }

        if let data = defaults.data(forKey: epgSourcesKey),
           let list = try? JSONDecoder().decode([EPGSource].self, from: data) {
            epgSources = list
        }
        if let data = defaults.data(forKey: epgKey),
           let database = try? JSONDecoder().decode(EPGDatabase.self, from: data) {
            epgDatabase = database
        }
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: sourcesKey)
        }
        var stored: [String: [Channel]] = [:]
        for (id, list) in channelsBySource { stored[id.uuidString] = list }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: channelsKey)
        }
        if let data = try? JSONEncoder().encode(selectedSourceID) {
            defaults.set(data, forKey: selectedKey)
        }
    }

    private func persistEPG() {
        if let data = try? JSONEncoder().encode(epgSources) {
            defaults.set(data, forKey: epgSourcesKey)
        }
        if let data = try? JSONEncoder().encode(epgDatabase) {
            defaults.set(data, forKey: epgKey)
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    // MARK: - 内置示例

    private func seedDemoIfNeeded() {
        guard sources.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "m3u"),
              let data = try? Data(contentsOf: url) else { return }
        let channels = PlaylistParser.parse(data: data)
        guard !channels.isEmpty else { return }
        var source = Source(name: "内置示例", kind: .builtin, location: "demo.m3u")
        source.count = channels.count
        sources = [source]
        channelsBySource = [source.id: channels]
        selectedSourceID = source.id
        persistSources()
    }

    private func defaultName(for location: String) -> String {
        if location.hasSuffix("/") { return "订阅列表" }
        let name = (location as NSString).lastPathComponent
        return name.isEmpty ? "订阅列表" : name
    }
}

enum StoreError: LocalizedError {
    case badURL
    case emptyPlaylist
    case emptyEPG

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址为空或格式不正确"
        case .emptyPlaylist: return "播放列表为空，或格式无法识别"
        case .emptyEPG: return "EPG 为空，或不是 XMLTV 格式"
        }
    }
}

enum EPGService {
    static func fetch(_ urlString: String) async throws -> EPGDatabase {
        let response = try await HTTPService.fetch(urlString, headers: [:])
        return XMLTVParser.parse(data: response.data)
    }
}
