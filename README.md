# Espobase for Swift

The Espobase client for iOS, macOS, tvOS, watchOS and server-side Swift: your project's database, App Authentication,
Storage and edge functions, with `async`/`await`. No dependencies (URLSession for HTTP, plain Swift for hashing).
Requires Swift 5.9+; iOS 15, macOS 12, tvOS 15 or watchOS 8.

> Status: version 0.1.0. SwiftPM installs from a repository whose root holds `Package.swift`, so this package is
> published to its own repository (`github.com/Naples210/espobase-swift`) from the Espobase monorepo's `packages/swift`.
> Realtime (WebSockets) is not in this version: use the REST API, or the JavaScript client for realtime.

## Install

Xcode: File › Add Package Dependencies…, then the repository URL. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Naples210/espobase-swift", from: "0.1.0")
```

## Create a client

```swift
import Espobase

let espobase = try EspobaseClient(
    url: URL(string: "https://api.espobase.com/project/<your project ref>")!,
    key: "eb_pk_…"  // the PUBLISHABLE key: safe in an app
)
```

Never put a secret key (`eb_sk_…`) in an app: `EspobaseClient` refuses it unless you set `options.serverSide = true`
(for a trusted server).

## Database

```swift
struct Todo: Codable { let id: Int; let title: String; let done: Bool }

let todos: [Todo] = try await espobase.from("todos")
    .select()
    .eq("done", false)
    .order("created_at", ascending: false)
    .limit(20)
    .execute()

try await espobase.from("todos").insert(["title": "Buy milk"]).run()
let created: [Todo] = try await espobase.from("todos").insert(["title": "Walk the dog"]).select().execute()
try await espobase.from("todos").update(["done": true]).eq("id", 1).run()
try await espobase.from("todos").delete().eq("id", 1).run()
```

`update()` and `delete()` refuse to run without a filter. Filters: `eq neq gt gte lt lte like ilike in isNull is`;
`order`, `limit`, `range`, `single()`. Database functions: `let rows: [Match] = try await espobase.rpc("match_documents", params: args)`.
Row level security applies to everything, as the signed-in user.

## Sign-up and sign-in

```swift
_ = try await espobase.auth.signUp(email: email, password: password, redirectTo: "myapp://auth/callback")
let session = try await espobase.auth.signInWithPassword(email: email, password: password)

for await (event, session) in await espobase.auth.authStateChanges { … }   // SIGNED_IN, SIGNED_OUT, TOKEN_REFRESHED, USER_UPDATED
```

The session is kept in the Keychain (this device, after first unlock) and refreshed for you. Pass a `SessionStorage` in
`ClientOptions` to keep it elsewhere. Add your app link (`myapp://auth/callback`) under Authentication › Settings ›
Allowed redirect URLs for confirmation and password-reset emails.

### Sign in with Apple

Turn it on under Authentication › Providers › Apple, with your bundle ID. Then:

```swift
let nonce = AppleNonce()
request.requestedScopes = [.email]
request.nonce = nonce.hashed                       // Apple gets the hash …

// in the authorization delegate:
let token = String(decoding: credential.identityToken!, as: UTF8.self)
let session = try await espobase.auth.signInWithIdToken(token: token, nonce: nonce.raw)   // … Espobase gets the raw value
```

### Google, GitHub

```swift
let url = try await espobase.auth.signInWithOAuth(provider: .google, redirectTo: "myapp://auth/callback")
// open `url` with ASWebAuthenticationSession(callbackURLScheme: "myapp"); the callback URL has ?code=…
let session = try await espobase.auth.exchangeCodeForSession(code)
```

Only this device can finish the sign-in (PKCE). Two-step sign-in: a sign-in that needs a second step throws
`mfa_required`; finish it with `espobase.auth.mfa.verify(code:)`.

## Storage

```swift
let photos = try espobase.storage.from("photos")
try await photos.upload(path: "\(userId)/me.jpg", data: jpegData, contentType: "image/jpeg")
let bytes = try await photos.download(path: "\(userId)/me.jpg")
let thumb = try photos.publicUrl(path: "logo.png", transform: ImageTransform(width: 200))   // Pro and Group
let link = try await photos.createSignedUrl(path: "\(userId)/me.jpg", expiresIn: 600)
```

## Edge functions

```swift
let answer = try await espobase.functions.invoke("hello", body: ["name": "Ada"])
let greeting = try answer.decode(Greeting.self)
```

## Errors

Everything throws `EspobaseError` (`status`, `code`, `message`, `details`, `hint`); `status` is 0 for network and
client-side errors.

## Tests

`swift test` (25 tests: SHA-256 and PKCE vectors, the request each call makes, token refresh, two-step sign-in,
Sign in with Apple, storage and functions) with a mock transport: no network.
