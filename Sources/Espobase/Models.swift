import Foundation

public enum AuthProvider: String, Codable, Sendable {
    case email, google, github, apple
}

/// Social sign-in providers (turned on per project in the dashboard).
public enum OAuthProvider: String, Codable, Sendable {
    case google, github, apple
}

public struct User: Codable, Sendable, Equatable {
    public let id: String
    public let email: String
    public let emailVerified: Bool
    public let appRole: String
    /// The first way this user signed in.
    public let provider: AuthProvider
    /// Every sign-in method linked to the user.
    public let providers: [AuthProvider]
    public let createdAt: String
    public let lastSignInAt: String?
}

public struct Session: Codable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    /// Epoch seconds.
    public let expiresAt: Int
    public let refreshToken: String
    public let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case refreshToken = "refresh_token"
        case user
    }

    func with(user: User) -> Session {
        Session(
            accessToken: accessToken, tokenType: tokenType, expiresIn: expiresIn, expiresAt: expiresAt,
            refreshToken: refreshToken, user: user)
    }
}

public enum AuthEvent: String, Sendable {
    case signedIn = "SIGNED_IN"
    case signedOut = "SIGNED_OUT"
    case tokenRefreshed = "TOKEN_REFRESHED"
    case userUpdated = "USER_UPDATED"
}

public struct MfaFactor: Codable, Sendable, Equatable {
    public let id: String
    public let type: MfaFactorType
    public let verified: Bool
    public let createdAt: String
}

/// A Storage file, as listed.
public struct StorageFile: Codable, Sendable, Equatable {
    public let id: String
    /// Full path in the bucket, e.g. "avatars/me.png".
    public let name: String
    public let size: Int
    public let mimeType: String?
    public let sha256: String?
    public let createdAt: String
    public let updatedAt: String
}

public struct StorageUploadResult: Codable, Sendable, Equatable {
    public let id: String
    public let bucket: String
    public let path: String
    public let size: Int
    /// SHA-256 of the stored bytes (hex).
    public let sha256: String
}

/// Resizing for stored images (Pro and Group). Every value is optional but a width or a height is needed.
public struct ImageTransform: Sendable, Equatable {
    public enum Resize: String, Sendable { case cover, contain, fill, inside, outside }
    public enum Format: String, Sendable { case webp, jpeg, png, avif }
    public var width: Int?
    public var height: Int?
    public var resize: Resize?
    public var quality: Int?
    public var format: Format?

    public init(width: Int? = nil, height: Int? = nil, resize: Resize? = nil, quality: Int? = nil, format: Format? = nil) {
        self.width = width
        self.height = height
        self.resize = resize
        self.quality = quality
        self.format = format
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let width { items.append(URLQueryItem(name: "width", value: String(width))) }
        if let height { items.append(URLQueryItem(name: "height", value: String(height))) }
        if let resize { items.append(URLQueryItem(name: "resize", value: resize.rawValue)) }
        if let quality { items.append(URLQueryItem(name: "quality", value: String(quality))) }
        if let format { items.append(URLQueryItem(name: "format", value: format.rawValue)) }
        return items
    }
}
