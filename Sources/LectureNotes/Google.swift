import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

struct DriveFolder: Identifiable, Hashable {
    let id: String
    let name: String
}

enum GoogleError: LocalizedError {
    case missingClientID, notSignedIn, cancelled, http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "This build has no Google client ID. Rebuild with google-client-id.txt (see README)."
        case .notSignedIn: "Sign in with Google first."
        case .cancelled: "Google sign-in was cancelled."
        case .http(let code, let body): "Google API error \(code): \(body.prefix(300))"
        }
    }
}

@MainActor
final class Google: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Google()

    @Published private(set) var email: String?
    @Published private(set) var folders: [DriveFolder] = []

    // drive.file = only files/folders this app creates. Non-sensitive scope: no Google security review needed.
    private let scope = "https://www.googleapis.com/auth/drive.file"
    static let defaultFolderName = "Lecture Notes"
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?

    /// False when the app was built without a Google client ID (see README); Docs export falls back to copy & paste.
    var isConfigured: Bool { !clientID.isEmpty }

    private var refreshToken: String? {
        get { Keychain.get("google.refreshToken") }
        set { Keychain.set(newValue, for: "google.refreshToken") }
    }

    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    override private init() {
        super.init()
        email = UserDefaults.standard.string(forKey: "google.email")
        // Builds before one-click sign-in used a per-user client ID and full-Drive scope; those sessions can't be reused.
        if UserDefaults.standard.string(forKey: "googleClientID") != nil {
            UserDefaults.standard.removeObject(forKey: "googleClientID")
            signOut()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }

    // MARK: OAuth (PKCE, iOS-type client, custom scheme redirect)

    func signIn() async throws {
        guard !clientID.isEmpty else { throw GoogleError.missingClientID }
        let scheme = "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let redirect = scheme + ":/oauthredirect"
        let verifier = Self.base64URL(Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? GoogleError.cancelled) }
            }
            session.presentationContextProvider = self
            authSession = session
            NSApp.activate()
            session.start()
        }
        authSession = nil

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw GoogleError.cancelled }

        let json = try await tokenRequest([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ])
        refreshToken = json["refresh_token"] as? String
        storeAccessToken(json)

        let about = try await get("https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")
        email = (about["user"] as? [String: Any])?["emailAddress"] as? String
        UserDefaults.standard.set(email, forKey: "google.email")
        objectWillChange.send()
        try await loadFolders()
        if Prefs.shared.folderID.isEmpty || !folders.contains(where: { $0.id == Prefs.shared.folderID }) {
            var folder = folders.first { $0.name == Self.defaultFolderName }
            if folder == nil { folder = try await createFolder(Self.defaultFolderName) }
            guard let folder else { return }
            Prefs.shared.folderID = folder.id
            Prefs.shared.folderName = folder.name
        }
    }

    func signOut() {
        refreshToken = nil
        accessToken = nil
        email = nil
        folders = []
        UserDefaults.standard.removeObject(forKey: "google.email")
    }

    private func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refreshToken else { throw GoogleError.notSignedIn }
        let json: [String: Any]
        do {
            json = try await tokenRequest([
                "client_id": clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ])
        } catch GoogleError.http(let code, _) where code == 400 || code == 401 {
            // Revoked, expired, or issued to an older client ID: start fresh.
            signOut()
            throw GoogleError.notSignedIn
        }
        storeAccessToken(json)
        guard let accessToken else { throw GoogleError.notSignedIn }
        return accessToken
    }

    private func storeAccessToken(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3000)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        return try await Self.send(request)
    }

    // MARK: Drive

    func loadFolders() async throws {
        var all: [DriveFolder] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                .init(name: "q", value: "mimeType='application/vnd.google-apps.folder' and trashed=false"),
                .init(name: "fields", value: "nextPageToken,files(id,name)"),
                .init(name: "orderBy", value: "name"),
                .init(name: "pageSize", value: "1000"),
            ]
            if let pageToken { components.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await get(components.url!.absoluteString)
            let files = json["files"] as? [[String: Any]] ?? []
            all += files.compactMap { f in
                guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
                return DriveFolder(id: id, name: name)
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && all.count < 5000
        folders = all
    }

    @discardableResult
    func createFolder(_ name: String) async throws -> DriveFolder {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "mimeType": "application/vnd.google-apps.folder",
        ])
        let json = try await Self.send(request)
        let folder = DriveFolder(id: json["id"] as? String ?? "", name: json["name"] as? String ?? name)
        folders = (folders + [folder]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folder
    }

    /// Uploads HTML and lets Drive convert it into a native Google Doc. Returns the doc URL.
    func createDoc(title: String, html: String, folderID: String) async throws -> URL {
        var metadata: [String: Any] = ["name": title, "mimeType": "application/vnd.google-apps.document"]
        if !folderID.isEmpty { metadata["parents"] = [folderID] }

        let boundary = "LectureNotes-\(UUID().uuidString)"
        var body = Data()
        body += "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
        body += try JSONSerialization.data(withJSONObject: metadata)
        body += "\r\n--\(boundary)\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n"
        body += html
        body += "\r\n--\(boundary)--\r\n"

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink&supportsAllDrives=true")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let json = try await Self.send(request)
        if let link = json["webViewLink"] as? String, let url = URL(string: link) { return url }
        let id = json["id"] as? String ?? ""
        return URL(string: "https://docs.google.com/document/d/\(id)/edit")!
    }

    /// Renames a Doc this app created. `docURL` looks like https://docs.google.com/document/d/<id>/edit.
    func renameDoc(_ docURL: URL, to name: String) async throws {
        let parts = docURL.pathComponents
        guard let i = parts.firstIndex(of: "d"), i + 1 < parts.count else { return }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(parts[i + 1])?supportsAllDrives=true")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await Self.send(request)
    }

    private func get(_ url: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return try await Self.send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw GoogleError.http(status, String(decoding: data, as: UTF8.self)) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    static func += (lhs: inout Data, rhs: String) { lhs.append(Data(rhs.utf8)) }
}
