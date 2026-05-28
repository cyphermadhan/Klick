import Foundation

@MainActor
final class ChannelStore: ObservableObject {
    @Published private(set) var channels: [Channel] = []
    @Published var activeChannelId: String?

    var activeChannel: Channel? {
        channels.first { $0.id == activeChannelId }
    }

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("klick-channels.json")
    }

    // MARK: - Persistence

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder.klick.decode(StoredState.self, from: data) {
            channels = stored.channels
            activeChannelId = stored.activeChannelId
        }

        if channels.isEmpty {
            migrateFromLegacyKey()
        }
    }

    func save() {
        let state = StoredState(channels: channels, activeChannelId: activeChannelId)
        if let data = try? JSONEncoder.klick.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String, key: Data, members: [ChannelMember] = []) -> Channel {
        let channel = Channel(
            id: UUID().uuidString,
            name: name,
            members: members,
            createdAt: .now,
            creatorName: DeviceName.current
        )
        try? KeyStore(forChannel: channel.id).save(key)
        channels.append(channel)
        if activeChannelId == nil { activeChannelId = channel.id }
        save()
        return channel
    }

    func delete(id: String) {
        channels.removeAll { $0.id == id }
        try? KeyStore(forChannel: id).clear()
        if activeChannelId == id {
            activeChannelId = channels.first?.id
        }
        save()
    }

    func addMember(_ member: ChannelMember, to channelId: String) {
        guard let idx = channels.firstIndex(where: { $0.id == channelId }) else { return }
        if channels[idx].members.contains(where: { $0.name == member.name }) { return }
        channels[idx].members.append(member)
        save()
    }

    func removeMember(name: String, from channelId: String) {
        guard let idx = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[idx].members.removeAll { $0.name == name }
        save()
    }

    func rename(_ channelId: String, to newName: String) {
        guard let idx = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[idx].name = newName
        save()
    }

    func toggleBroadcast(_ channelId: String) {
        guard let idx = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[idx].isBroadcast.toggle()
        save()
    }

    /// Join or create a channel from a passphrase. If a channel with the
    /// derived ID already exists locally, just switch to it. Otherwise
    /// create it with the derived key.
    @discardableResult
    func joinByPassphrase(_ passphrase: String) -> Channel {
        let channelId = PassphraseJoin.deriveChannelId(from: passphrase)
        // Already have this channel?
        if let existing = channels.first(where: { $0.id == channelId }) {
            setActive(existing.id)
            return existing
        }
        let key = PassphraseJoin.deriveKey(from: passphrase)
        let name = PassphraseJoin.deriveChannelName(from: passphrase)
        let member = ChannelMember(name: DeviceName.current, addedAt: .now)
        let channel = Channel(
            id: channelId,
            name: name,
            members: [member],
            createdAt: .now,
            creatorName: nil  // Open channel — no single creator
        )
        try? KeyStore(forChannel: channel.id).save(key)
        channels.append(channel)
        activeChannelId = channel.id
        save()
        return channel
    }

    func setActive(_ channelId: String) {
        guard channels.contains(where: { $0.id == channelId }) else { return }
        activeChannelId = channelId
        save()
    }

    func key(for channelId: String) -> Data? {
        try? KeyStore(forChannel: channelId).load()
    }

    var nextDefaultName: String {
        "CH\(channels.count + 1)"
    }

    // MARK: - Migration

    private func migrateFromLegacyKey() {
        guard let legacyKey = try? KeyStore().load() else { return }
        let ch1 = Channel(
            id: UUID().uuidString,
            name: "CH1",
            members: [],
            createdAt: .now
        )
        try? KeyStore(forChannel: ch1.id).save(legacyKey)
        channels = [ch1]
        activeChannelId = ch1.id
        save()
    }
}

// MARK: - Storage format

private struct StoredState: Codable {
    let channels: [Channel]
    let activeChannelId: String?
}

// MARK: - Coder helpers

private extension JSONEncoder {
    static let klick: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let klick: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
