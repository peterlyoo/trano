import Foundation

public struct AppearanceProfile: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var background: String
    public var appearance: AppearancePreferences

    public init(id: String = UUID().uuidString.lowercased(), name: String, settings: TerminalSettings) {
        self.id = id; self.name = name
        fontName = settings.fontName; fontSize = settings.fontSize
        background = settings.background; appearance = settings.appearance
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !fontName.isEmpty, fontName.utf8.count <= 200, fontSize.isFinite, (9...40).contains(fontSize),
              AppearancePreferences.isHexColor(background) else { throw TerminalError.invalid("Invalid appearance profile.") }
        try appearance.validate()
    }
}

extension TerminalSettings {
    public func resolvedAppearance(for paneID: String) -> TerminalSettings {
        guard let id = paneAppearanceProfiles[paneID], let profile = appearanceProfiles.first(where: { $0.id == id }) else { return self }
        var result = self
        result.fontName = profile.fontName; result.fontSize = profile.fontSize
        result.background = profile.background; result.appearance = profile.appearance
        return result
    }

    public func validateAppearanceProfiles() throws {
        guard appearanceProfiles.count <= 64, Set(appearanceProfiles.map(\.id)).count == appearanceProfiles.count,
              paneAppearanceProfiles.count <= 4096,
              paneAppearanceProfiles.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw TerminalError.invalid("Invalid appearance profile collection.")
        }
        for profile in appearanceProfiles { try profile.validate() }
        let ids = Set(appearanceProfiles.map(\.id))
        guard paneAppearanceProfiles.values.allSatisfy(ids.contains) else { throw TerminalError.invalid("Unknown appearance profile.") }
    }
}

extension TerminalRuntime {
    public func setAppearanceProfile(_ profileID: String?, paneID: String) throws {
        try update { state in
            guard state.sessions.contains(where: { $0.id == paneID }),
                  profileID == nil || state.settings.appearanceProfiles.contains(where: { $0.id == profileID }) else { throw TerminalError.invalid("Unknown pane or appearance profile.") }
            state.settings.paneAppearanceProfiles[paneID] = profileID
        }
    }

    public func saveAppearanceProfile(_ profile: AppearanceProfile) throws {
        try profile.validate()
        try update { state in
            if let index = state.settings.appearanceProfiles.firstIndex(where: { $0.id == profile.id }) { state.settings.appearanceProfiles[index] = profile }
            else { state.settings.appearanceProfiles.append(profile) }
            try state.settings.validateAppearanceProfiles()
        }
    }

    public func removeAppearanceProfile(_ id: String) throws {
        try update { state in
            state.settings.appearanceProfiles.removeAll { $0.id == id }
            state.settings.paneAppearanceProfiles = state.settings.paneAppearanceProfiles.filter { $0.value != id }
        }
    }
}
