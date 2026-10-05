import Foundation

/// An error from Espobase or the network. `status` is the HTTP status (0 for network and client-side errors) and
/// `code` is an Espobase or PostgreSQL error code such as `invalid_credentials` or `42501`.
public struct EspobaseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int
    public let code: String
    public let message: String
    public let details: String?
    public let hint: String?
    /// With `mfa_required` / `mfa_enrollment_required`: the sign-in waits for its second step (`auth.mfa.verify`).
    public let mfa: MfaPending?

    public init(
        status: Int, code: String, message: String, details: String? = nil, hint: String? = nil, mfa: MfaPending? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.hint = hint
        self.mfa = mfa
    }

    public var description: String { "EspobaseError(\(status) \(code): \(message))" }

    static func client(_ code: String, _ message: String) -> EspobaseError {
        EspobaseError(status: 0, code: code, message: message)
    }

    static let notSignedIn = EspobaseError(status: 401, code: "no_session", message: "Not signed in.")
}

/// A sign-in that waits for its second step.
public struct MfaPending: Sendable, Equatable {
    public struct Factor: Sendable, Equatable {
        public let id: String
        public let type: MfaFactorType
    }
    public let enrollmentRequired: Bool
    public let factors: [Factor]
    /// Whether a recovery code can be used instead.
    public let recoveryCodes: Bool
}

public enum MfaFactorType: String, Codable, Sendable {
    case totp
    case email
}
