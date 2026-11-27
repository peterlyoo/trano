import Foundation

public enum AccountResetCreditStatus: String, Codable {
    case available, redeeming, redeemed, unknown
}

public struct AccountResetCredit: Codable, Equatable, Identifiable {
    public let id: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let resetType: String
    public let status: AccountResetCreditStatus
    public let title: String?
    public let description: String?

    private enum CodingKeys: String, CodingKey {
        case id, grantedAt, expiresAt, resetType, status, title, description
    }

    private init(id: String, grantedAt: Date, expiresAt: Date?, resetType: String,
                 status: AccountResetCreditStatus, title: String?, description: String?) {
        self.id = id; self.grantedAt = grantedAt; self.expiresAt = expiresAt; self.resetType = resetType
        self.status = status; self.title = title; self.description = description
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        let id = try value.decode(String.self, forKey: .id)
        let resetType = try value.decode(String.self, forKey: .resetType)
        let grantedAt = try value.decode(Date.self, forKey: .grantedAt)
        let expiresAt = try value.decodeIfPresent(Date.self, forKey: .expiresAt)
        guard Self.identifier(id), Self.identifier(resetType), Self.validDate(grantedAt),
              expiresAt.map(Self.validDate) ?? true else { throw TerminalError.invalid("Invalid cached reset credit") }
        self.id = id; self.resetType = resetType; self.grantedAt = grantedAt; self.expiresAt = expiresAt
        status = AccountResetCreditStatus(rawValue: try value.decode(String.self, forKey: .status)) ?? .unknown
        title = Self.displayText(try? value.decodeIfPresent(String.self, forKey: .title), limit: 512)
        description = Self.displayText(try? value.decodeIfPresent(String.self, forKey: .description), limit: 2_048)
    }

    static func parse(_ value: Any) -> AccountResetCredit? {
        guard let value = value as? [String: Any], let id = value["id"] as? String, identifier(id),
              let resetType = value["resetType"] as? String, identifier(resetType),
              let status = value["status"] as? String, let grantedAt = timestamp(value["grantedAt"]) else { return nil }
        let expiresAt: Date?
        if let raw = value["expiresAt"], !(raw is NSNull) {
            guard let parsed = timestamp(raw) else { return nil }
            expiresAt = parsed
        } else { expiresAt = nil }
        return AccountResetCredit(id: id, grantedAt: grantedAt, expiresAt: expiresAt, resetType: resetType,
                                  status: AccountResetCreditStatus(rawValue: status) ?? .unknown,
                                  title: displayText(value["title"] as? String, limit: 512),
                                  description: displayText(value["description"] as? String, limit: 2_048))
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let number = AccountUsageAdapter.number(value), number.rounded(.towardZero) == number,
              abs(number) <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: number)
    }

    private static func validDate(_ value: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite && abs(seconds) <= 253_402_300_799
    }

    private static func displayText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        var result = String(value.prefix(limit))
        while result.utf8.count > limit { result.removeLast() }
        return result
    }
}

public struct AccountResetCredits: Codable, Equatable {
    public let availableCount: Int
    public let credits: [AccountResetCredit]?
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey { case availableCount, credits, observedAt }
    private static let maximumAvailableCount = 1_000_000
    private static let maximumDetailRows = 256

    private init(availableCount: Int, credits: [AccountResetCredit]?, observedAt: Date) {
        self.availableCount = availableCount; self.credits = credits; self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        let count = try value.decode(Int.self, forKey: .availableCount)
        let observation = try value.decode(Date.self, forKey: .observedAt)
        guard (0...Self.maximumAvailableCount).contains(count), observation.timeIntervalSince1970.isFinite else {
            throw TerminalError.invalid("Invalid cached reset summary")
        }
        availableCount = count; observedAt = observation
        if var details = try? value.nestedUnkeyedContainer(forKey: .credits) {
            var parsed: [AccountResetCredit] = []
            for _ in 0..<Self.maximumDetailRows {
                guard !details.isAtEnd else { break }
                let decoder = try details.superDecoder()
                if let credit = try? AccountResetCredit(from: decoder) { parsed.append(credit) }
            }
            credits = parsed
        } else { credits = nil }
    }

    static func parse(_ value: Any?, observedAt: Date) -> AccountResetCredits? {
        guard let value = value as? [String: Any], let count = AccountUsageAdapter.number(value["availableCount"]),
              count.rounded(.towardZero) == count, (0...Double(maximumAvailableCount)).contains(count),
              observedAt.timeIntervalSince1970.isFinite else { return nil }
        let credits = (value["credits"] as? [Any]).map { rows in
            rows.prefix(maximumDetailRows).compactMap(AccountResetCredit.parse)
        }
        return AccountResetCredits(availableCount: Int(count), credits: credits, observedAt: observedAt)
    }

    func freshAvailableCount(now: Date) -> Int? {
        let age = now.timeIntervalSince(observedAt)
        guard now.timeIntervalSince1970.isFinite, age.isFinite, (0...300).contains(age),
              (0...Self.maximumAvailableCount).contains(availableCount) else { return nil }
        let expired = Set((credits ?? []).filter { $0.status == .available && ($0.expiresAt.map { $0 <= now } ?? false) }.map(\.id))
        return max(0, availableCount - expired.count)
    }
}

extension AccountUsageSnapshot {
    public func freshAvailableResetCount(now: Date = Date()) -> Int? {
        guard status != .authenticationRequired, status != .unavailable else { return nil }
        return resetCredits?.freshAvailableCount(now: now)
    }
}
