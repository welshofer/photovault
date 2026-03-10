import Foundation
import AuthenticationServices
import Security

// MARK: - Google Drive API Client

/// Handles all Google Drive API interactions with resumable uploads
actor GoogleDriveClient {
    
    // OAuth configuration — replace with your credentials
    private let clientID: String
    private let clientSecret: String  // For installed apps
    private let redirectURI = "com.welshofer.photovault:/oauth2callback"
    
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    
    private let session: URLSession
    private let baseURL = "https://www.googleapis.com"
    
    // Rate limiting
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval = 0.1  // 10 requests/second max
    
    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600  // 1 hour for large uploads
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - OAuth 2.0 Flow
    
    /// Generate the OAuth authorization URL for user consent
    func authorizationURL() -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }
    
    /// Exchange authorization code for tokens
    func exchangeCodeForTokens(code: String) async throws {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        request.httpBody = body.percentEncoded()
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60))
    }
    
    /// Refresh the access token
    private func refreshAccessToken() async throws {
        guard let refreshToken else {
            throw DriveError.notAuthenticated
        }
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token"
        ]
        request.httpBody = body.percentEncoded()
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60))
    }
    
    /// Ensure we have a valid access token (internal for extensions)
    func ensureValidTokenPublic() async throws -> String {
        return try await ensureValidToken()
    }

    /// Ensure we have a valid access token
    private func ensureValidToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
            return token
        }
        try await refreshAccessToken()
        guard let token = accessToken else {
            throw DriveError.notAuthenticated
        }
        return token
    }
    
    /// Persist tokens to Keychain (simplified — use proper Keychain wrapper in production)
    func saveTokens(to keychain: KeychainWrapper) throws {
        if let accessToken {
            try keychain.set(accessToken, forKey: "gdrive_access_token")
        }
        if let refreshToken {
            try keychain.set(refreshToken, forKey: "gdrive_refresh_token")
        }
        if let tokenExpiry {
            try keychain.set(tokenExpiry.timeIntervalSince1970, forKey: "gdrive_token_expiry")
        }
    }
    
    func loadTokens(from keychain: KeychainWrapper) throws {
        accessToken = try keychain.string(forKey: "gdrive_access_token")
        refreshToken = try keychain.string(forKey: "gdrive_refresh_token")
        if let expiry = try keychain.double(forKey: "gdrive_token_expiry") {
            tokenExpiry = Date(timeIntervalSince1970: expiry)
        }
    }
    
    // MARK: - Folder Operations
    
    /// Create a folder in Google Drive, returns folder ID
    func createFolder(name: String, parentID: String? = nil) async throws -> String {
        let token = try await ensureValidToken()
        await rateLimit()
        
        let url = URL(string: "\(baseURL)/drive/v3/files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        if let parentID {
            metadata["parents"] = [parentID]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        
        let file = try JSONDecoder().decode(DriveFile.self, from: data)
        return file.id
    }
    
    /// Find a folder by name within a parent, returns folder ID if exists
    func findFolder(name: String, parentID: String? = nil) async throws -> String? {
        let token = try await ensureValidToken()
        await rateLimit()
        
        var query = "name = '\(name.escapedForQuery())' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        if let parentID {
            query += " and '\(parentID)' in parents"
        }
        
        var components = URLComponents(string: "\(baseURL)/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]
        
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        
        let fileList = try JSONDecoder().decode(DriveFileList.self, from: data)
        return fileList.files.first?.id
    }
    
    /// Create folder hierarchy, returns the leaf folder ID
    /// E.g., ["Photos", "2024", "Vacation"] creates nested folders
    func createFolderPath(_ path: [String], rootParentID: String? = nil) async throws -> String {
        var currentParentID = rootParentID
        
        for folderName in path {
            // Check if folder already exists
            if let existingID = try await findFolder(name: folderName, parentID: currentParentID) {
                currentParentID = existingID
            } else {
                // Create the folder
                currentParentID = try await createFolder(name: folderName, parentID: currentParentID)
            }
        }
        
        guard let finalID = currentParentID else {
            throw DriveError.folderCreationFailed("Empty path")
        }
        return finalID
    }
    
    // MARK: - Resumable Upload
    
    /// Initiate a resumable upload session, returns the upload URI
    func initiateResumableUpload(
        filename: String,
        mimeType: String,
        fileSize: Int64,
        parentFolderID: String
    ) async throws -> String {
        let token = try await ensureValidToken()
        await rateLimit()
        
        let url = URL(string: "\(baseURL)/upload/drive/v3/files?uploadType=resumable")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        
        let metadata: [String: Any] = [
            "name": filename,
            "parents": [parentFolderID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let uploadURI = httpResponse.value(forHTTPHeaderField: "Location") else {
            throw DriveError.uploadInitFailed
        }
        
        return uploadURI
    }
    
    /// Upload a chunk of data to a resumable upload session
    /// Returns the file ID on completion, nil if more chunks needed
    func uploadChunk(
        uploadURI: String,
        data: Data,
        offset: Int64,
        totalSize: Int64
    ) async throws -> UploadChunkResult {
        await rateLimit()
        
        let url = URL(string: uploadURI)!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        
        let endByte = offset + Int64(data.count) - 1
        request.setValue("bytes \(offset)-\(endByte)/\(totalSize)", forHTTPHeaderField: "Content-Range")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        
        let (responseData, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200, 201:
            // Upload complete
            let file = try JSONDecoder().decode(DriveFile.self, from: responseData)
            return .completed(fileID: file.id)
            
        case 308:
            // Incomplete, more chunks needed
            if let rangeHeader = httpResponse.value(forHTTPHeaderField: "Range"),
               let uploadedRange = parseRangeHeader(rangeHeader) {
                return .incomplete(uploadedBytes: uploadedRange + 1)
            }
            return .incomplete(uploadedBytes: offset + Int64(data.count))
            
        case 404:
            // Upload session expired, need to restart
            throw DriveError.uploadSessionExpired
            
        case 500, 502, 503, 504:
            // Retriable server error
            throw DriveError.serverError(httpResponse.statusCode)
            
        default:
            throw DriveError.uploadFailed(httpResponse.statusCode, String(data: responseData, encoding: .utf8))
        }
    }
    
    /// Query the status of a resumable upload
    func queryUploadStatus(uploadURI: String, totalSize: Int64) async throws -> Int64 {
        await rateLimit()
        
        let url = URL(string: uploadURI)!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("bytes */\(totalSize)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }
        
        if httpResponse.statusCode == 308 {
            if let rangeHeader = httpResponse.value(forHTTPHeaderField: "Range"),
               let uploadedBytes = parseRangeHeader(rangeHeader) {
                return uploadedBytes + 1
            }
            return 0
        } else if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
            return totalSize
        }
        
        throw DriveError.uploadFailed(httpResponse.statusCode, nil)
    }
    
    /// High-level: Upload an entire file using resumable upload with chunking
    func uploadFile(
        fileURL: URL,
        filename: String,
        mimeType: String,
        parentFolderID: String,
        existingUploadURI: String? = nil,
        progressHandler: @escaping (Int64, Int64) -> Void
    ) async throws -> String {
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as! Int64
        let chunkSize: Int = 10 * 1024 * 1024  // 10 MB chunks
        
        // Get or create upload URI
        let uploadURI: String
        var uploadedBytes: Int64 = 0
        
        if let existingURI = existingUploadURI {
            uploadURI = existingURI
            // Query current progress
            do {
                uploadedBytes = try await queryUploadStatus(uploadURI: existingURI, totalSize: fileSize)
            } catch DriveError.uploadSessionExpired {
                // Session expired, start fresh
                uploadedBytes = 0
            }
        } else {
            uploadURI = try await initiateResumableUpload(
                filename: filename,
                mimeType: mimeType,
                fileSize: fileSize,
                parentFolderID: parentFolderID
            )
        }
        
        // Open file for reading
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        // Seek to resume position
        try fileHandle.seek(toOffset: UInt64(uploadedBytes))
        
        // Upload in chunks
        while uploadedBytes < fileSize {
            let remainingBytes = fileSize - uploadedBytes
            let currentChunkSize = min(Int(remainingBytes), chunkSize)
            
            guard let chunkData = try fileHandle.read(upToCount: currentChunkSize) else {
                throw DriveError.fileReadError
            }
            
            let result = try await withRetry(maxAttempts: 5) {
                try await self.uploadChunk(
                    uploadURI: uploadURI,
                    data: chunkData,
                    offset: uploadedBytes,
                    totalSize: fileSize
                )
            }
            
            switch result {
            case .completed(let fileID):
                progressHandler(fileSize, fileSize)
                return fileID
                
            case .incomplete(let newUploadedBytes):
                uploadedBytes = newUploadedBytes
                progressHandler(uploadedBytes, fileSize)
            }
        }
        
        throw DriveError.uploadFailed(0, "Upload loop ended without completion")
    }
    
    // MARK: - Helper Methods
    
    private func rateLimit() async {
        if let lastTime = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < minRequestInterval {
                try? await Task.sleep(nanoseconds: UInt64((minRequestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }
    
    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)
            throw DriveError.httpError(httpResponse.statusCode, errorBody)
        }
    }
    
    private func parseRangeHeader(_ header: String) -> Int64? {
        // Format: "bytes=0-12345"
        let pattern = /bytes=\d+-(\d+)/
        if let match = header.firstMatch(of: pattern) {
            return Int64(match.1)
        }
        return nil
    }
    
    private func withRetry<T>(
        maxAttempts: Int,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch DriveError.serverError {
                lastError = DriveError.serverError(500)
                // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                let delay = pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw error  // Non-retriable error
            }
        }
        
        throw lastError ?? DriveError.maxRetriesExceeded
    }
    
    // MARK: - Types
    
    enum UploadChunkResult {
        case completed(fileID: String)
        case incomplete(uploadedBytes: Int64)
    }
    
    enum DriveError: LocalizedError {
        case notAuthenticated
        case invalidResponse
        case httpError(Int, String?)
        case folderCreationFailed(String)
        case uploadInitFailed
        case uploadFailed(Int, String?)
        case uploadSessionExpired
        case serverError(Int)
        case maxRetriesExceeded
        case fileReadError
        
        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not authenticated with Google Drive"
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let code, let body):
                return "HTTP error \(code): \(body ?? "unknown")"
            case .folderCreationFailed(let reason):
                return "Failed to create folder: \(reason)"
            case .uploadInitFailed:
                return "Failed to initiate upload"
            case .uploadFailed(let code, let body):
                return "Upload failed with code \(code): \(body ?? "unknown")"
            case .uploadSessionExpired:
                return "Upload session expired, restart required"
            case .serverError(let code):
                return "Server error \(code), will retry"
            case .maxRetriesExceeded:
                return "Maximum retry attempts exceeded"
            case .fileReadError:
                return "Failed to read file"
            }
        }
    }
}

// MARK: - API Response Types

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

private struct DriveFile: Codable {
    let id: String
    let name: String?
    let mimeType: String?
}

private struct DriveFileList: Codable {
    let files: [DriveFile]
}

// MARK: - Helpers

extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> Data {
        map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }
}

extension String {
    func escapedForQuery() -> String {
        replacingOccurrences(of: "'", with: "\\'")
    }
}

// MARK: - Keychain Wrapper

struct KeychainWrapper {
    private let service = "com.photovault.credentials"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversionFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")"
            case .dataConversionFailed:
                return "Failed to convert keychain data"
            }
        }
    }

    func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func set(_ value: Double, forKey key: String) throws {
        try set(String(value), forKey: key)
    }

    func string(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func double(forKey key: String) throws -> Double? {
        guard let str = try string(forKey: key) else { return nil }
        return Double(str)
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - MIME Type Detection

extension URL {
    var mimeType: String {
        let ext = pathExtension.lowercased()
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "heic": "image/heic",
            "heif": "image/heif",
            "webp": "image/webp",
            "raw": "image/x-raw",
            "dng": "image/x-adobe-dng",
            "cr2": "image/x-canon-cr2",
            "nef": "image/x-nikon-nef",
            "arw": "image/x-sony-arw",
            "mov": "video/quicktime",
            "mp4": "video/mp4",
            "m4v": "video/x-m4v"
        ]
        return mimeTypes[ext] ?? "application/octet-stream"
    }
}
