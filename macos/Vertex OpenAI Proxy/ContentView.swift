import SwiftUI
import Combine
import Network
import Foundation
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Windows/WPF Style Theme Colors

extension Color {
    static let winBackground = Color(red: 0.957, green: 0.922, blue: 0.882) // #F4EBE1 (Warm Cream)
    static let winInputBg = Color.white
    static let winLabelText = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let winInputText = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let winBorderColor = Color(red: 0.86, green: 0.82, blue: 0.77)
    
    // 4 Control Button Colors (Pastels from WPF GUI)
    static let winStartBtn = Color(red: 0.72, green: 0.90, blue: 0.79)      // #B8E6CA
    static let winStopBtn = Color(red: 0.96, green: 0.68, blue: 0.68)       // #F5ADAD
    static let winRestartBtn = Color(red: 0.69, green: 0.82, blue: 0.99)    // #AFD0FD
    static let winSaveBtn = Color(red: 0.98, green: 0.85, blue: 0.58)       // #FBD994
}

struct WinControlButtonStyle: ButtonStyle {
    let backgroundColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.65 : 1.0))
            .cornerRadius(10)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Gemini 3.1 Pro Tool Calling LRU Cache

final class ToolCallLRUCache {
    static let shared = ToolCallLRUCache()
    private var cache: [String: (name: String, signature: String?)] = [:]
    private var keysOrder: [String] = []
    private var nameFallback: [String: String] = [:]
    private let maxCount = 1000
    private let lock = NSLock()
    
    func get(_ key: String) -> (name: String, signature: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let val = cache[key] else { return nil }
        if let idx = keysOrder.firstIndex(of: key) {
            keysOrder.remove(at: idx)
            keysOrder.append(key)
        }
        return val
    }
    
    func getSignatureByName(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return nameFallback[name]
    }
    
    func set(_ key: String, name: String, signature: String?) {
        lock.lock()
        defer { lock.unlock() }
        if cache[key] != nil {
            if let idx = keysOrder.firstIndex(of: key) { keysOrder.remove(at: idx) }
        } else if keysOrder.count >= maxCount {
            let oldest = keysOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[key] = (name, signature)
        keysOrder.append(key)
        if let sig = signature {
            nameFallback[name] = sig
        }
    }
}

// MARK: - Google ADC Authentication Engine

@MainActor
final class GoogleADCAuthManager: ObservableObject {
    static let shared = GoogleADCAuthManager()
    
    private let defaultClientId = "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com"
    private let defaultClientSecret = "d-mMDQealvRhY0EcPlXDfBbp"
    
    @Published var cachedAccessToken: String = ""
    @Published var tokenExpiresAt: Date = .distantPast
    @Published var storedRefreshToken: String = ""
    @Published var storedClientId: String = ""
    @Published var storedClientSecret: String = ""
    @Published var userEmail: String = ""
    @Published var isAdcAvailable: Bool = false
    @Published var authStatusMessage: String = ""
    @Published var showCopySuccessAlert: Bool = false
    
    init() {
        loadSavedCredentials()
    }
    
    var currentUsername: String {
        NSUserName().isEmpty ? "user" : NSUserName()
    }
    
    var defaultAdcPathHint: String {
        "이미 인증을 완료하셨으면 /Users/\(currentUsername)/.config/gcloud/application_default_credentials.json을 로드해주세요."
    }
    
    func loadSavedCredentials() {
        // Load persistent tokens from UserDefaults (fast path if we've parsed a JSON before)
        if let savedRefresh = UserDefaults.standard.string(forKey: "VOP_SAVED_REFRESH_TOKEN"), !savedRefresh.isEmpty {
            self.storedRefreshToken = savedRefresh
            self.storedClientId = UserDefaults.standard.string(forKey: "VOP_SAVED_CLIENT_ID") ?? defaultClientId
            self.storedClientSecret = UserDefaults.standard.string(forKey: "VOP_SAVED_CLIENT_SECRET") ?? defaultClientSecret
            self.userEmail = UserDefaults.standard.string(forKey: "VOP_SAVED_USER_EMAIL") ?? ""
            self.isAdcAvailable = true
            self.authStatusMessage = "자격 증명 로드됨"
            Task { @MainActor in
                LocalProxyServer.shared.startServer()
            }

            Task {
                _ = try? await self.getValidAccessToken()
            }
            return
        }

        // No saved token yet: auto-detect gcloud's ADC file on disk (App Sandbox is disabled,
        // so this path can be read without going through a file picker every launch).
        let adcPath = "/Users/\(currentUsername)/.config/gcloud/application_default_credentials.json"
        if let data = FileManager.default.contents(atPath: adcPath),
           let jsonString = String(data: data, encoding: .utf8),
           parseAndStoreAdcJson(jsonString: jsonString) {
            self.authStatusMessage = "gcloud 자격증명 자동 로드됨"
            LocalProxyServer.shared.startServer()
        }
    }
    
    func parseAndStoreAdcJson(jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        
        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            return false
        }
        
        let clientId = (json["client_id"] as? String) ?? defaultClientId
        let clientSecret = (json["client_secret"] as? String) ?? defaultClientSecret
        let account = (json["account"] as? String) ?? (json["client_email"] as? String) ?? ""
        let quotaProj = json["quota_project_id"] as? String
        
        self.storedRefreshToken = refreshToken
        self.storedClientId = clientId
        self.storedClientSecret = clientSecret
        self.userEmail = account
        self.isAdcAvailable = true
        
        UserDefaults.standard.set(refreshToken, forKey: "VOP_SAVED_REFRESH_TOKEN")
        UserDefaults.standard.set(clientId, forKey: "VOP_SAVED_CLIENT_ID")
        UserDefaults.standard.set(clientSecret, forKey: "VOP_SAVED_CLIENT_SECRET")
        UserDefaults.standard.set(account, forKey: "VOP_SAVED_USER_EMAIL")
        
        if let qp = quotaProj, !qp.isEmpty {
            LocalProxyServer.shared.projectId = qp
            LocalProxyServer.shared.saveDotEnv()
        }
        
        Task {
            do {
                let token = try await self.getValidAccessToken(forceRefresh: true)
                await self.fetchUserEmail(token: token)
                LocalProxyServer.shared.appendLog("[ADC] 자격증명 파일 로드 완료! (계정: \(self.userEmail.isEmpty ? "Google Cloud User" : self.userEmail))")
            } catch {
                LocalProxyServer.shared.appendLog("[ADC WARN] 토큰 갱신: \(error.localizedDescription)")
            }
        }
        return true
    }
    
    func copyAuthCommand() {
        #if os(macOS)
        let command = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" && gcloud auth application-default login"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        self.showCopySuccessAlert = true
        #endif
    }
    
    func fetchUserEmail(token: String) async {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["email"] as? String {
            self.userEmail = email
            UserDefaults.standard.set(email, forKey: "VOP_SAVED_USER_EMAIL")
        }
    }
    
    func logoutADC() {
        cachedAccessToken = ""
        tokenExpiresAt = .distantPast
        storedRefreshToken = ""
        userEmail = ""
        isAdcAvailable = false
        authStatusMessage = "로그아웃되었습니다."
        
        UserDefaults.standard.removeObject(forKey: "VOP_SAVED_REFRESH_TOKEN")
        UserDefaults.standard.removeObject(forKey: "VOP_SAVED_CLIENT_ID")
        UserDefaults.standard.removeObject(forKey: "VOP_SAVED_CLIENT_SECRET")
        UserDefaults.standard.removeObject(forKey: "VOP_SAVED_USER_EMAIL")
    }
    
    func getValidAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh && !cachedAccessToken.isEmpty && Date() < tokenExpiresAt {
            return cachedAccessToken
        }
        
        guard !storedRefreshToken.isEmpty else {
            throw NSError(domain: "ADC", code: 401, userInfo: [NSLocalizedDescriptionKey: "Google ADC 인증이 필요합니다. [인증 JSON 파일 로드]를 통해 자격증명을 불러와주세요."])
        }
        
        guard let tokenUrl = URL(string: "https://oauth2.googleapis.com/token") else {
            throw NSError(domain: "ADC", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Token URL"])
        }
        
        var req = URLRequest(url: tokenUrl)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let clientId = storedClientId.isEmpty ? defaultClientId : storedClientId
        let clientSecret = storedClientSecret.isEmpty ? defaultClientSecret : storedClientSecret
        
        let params = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": storedRefreshToken,
            "grant_type": "refresh_token"
        ]
        
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        
        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
              let respJson = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let newAccess = respJson["access_token"] as? String else {
            let errText = String(data: respData, encoding: .utf8) ?? "HTTP Error"
            throw NSError(domain: "ADC", code: 401, userInfo: [NSLocalizedDescriptionKey: "토큰 갱신 실패 (\(errText))"])
        }
        
        self.cachedAccessToken = newAccess
        let exp = (respJson["expires_in"] as? Double) ?? 3600
        self.tokenExpiresAt = Date().addingTimeInterval(exp - 120)
        self.isAdcAvailable = true
        
        if self.userEmail.isEmpty {
            await self.fetchUserEmail(token: newAccess)
        }
        return newAccess
    }
}

// MARK: - Native Local Proxy HTTP Server (Singleton)

@MainActor
final class LocalProxyServer: ObservableObject {
    static let shared = LocalProxyServer()
    
    @Published var isRunning = false
    @Published var projectId: String = "ai-test-508806" {
        didSet { UserDefaults.standard.set(projectId, forKey: "VOP_PROJECT_ID") }
    }
    @Published var location: String = "global" {
        didSet { UserDefaults.standard.set(location, forKey: "VOP_LOCATION") }
    }
    @Published var modelId: String = "gemini-3.7-flash" {
        didSet { UserDefaults.standard.set(modelId, forKey: "VOP_MODEL_ID") }
    }
    @Published var port: UInt16 = 3000 {
        didSet { UserDefaults.standard.set(port, forKey: "VOP_PORT") }
    }
    @Published var logOutput: String = ""
    @Published var isTestingPrompt: Bool = false
    @Published var testResultPreview: String = ""
    
    private var listener: NWListener?
    
    // Seed list shown until the live Vertex catalog loads (see listVertexModels).
    @Published var availableModels = [
        "gemini-4-argon",
        "gemini-3.7-flash",
        "gemini-3.1-pro-preview",
        "gemini-3.8-flash",
        "gemini-2.0-flash-exp",
        "gemini-2.0-flash-thinking-exp-01-21",
        "gemini-2.0-pro-exp-02-05",
        "gemini-1.5-pro-002",
        "gemini-1.5-flash-002",
        "gpt-4o",
        "gpt-4o-mini",
        "Gemini 3.1 Pro (Vision)"
    ]
    
    init() {
        loadDotEnv()
        appendBanner()
    }
    
    func appendLog(_ line: String) {
        logOutput += "\(line)\n"
    }
    
    func clearLogs() {
        logOutput = ""
    }
    
    func loadDotEnv() {
        if let savedPid = UserDefaults.standard.string(forKey: "VOP_PROJECT_ID"), !savedPid.isEmpty {
            self.projectId = savedPid
        }
        if let savedLoc = UserDefaults.standard.string(forKey: "VOP_LOCATION"), !savedLoc.isEmpty {
            self.location = savedLoc
        }
        if let savedMod = UserDefaults.standard.string(forKey: "VOP_MODEL_ID"), !savedMod.isEmpty {
            self.modelId = savedMod
        }
        if let savedPort = UserDefaults.standard.value(forKey: "VOP_PORT") as? UInt16, savedPort > 0 {
            self.port = savedPort
        }
    }
    
    func saveDotEnv() {
        UserDefaults.standard.set(projectId, forKey: "VOP_PROJECT_ID")
        UserDefaults.standard.set(location, forKey: "VOP_LOCATION")
        UserDefaults.standard.set(modelId, forKey: "VOP_MODEL_ID")
        UserDefaults.standard.set(port, forKey: "VOP_PORT")
    }
    
    func appendBanner() {
        appendLog("============================================================")
        appendLog("  Vertex AI Gemini Backend Server")
        appendLog("============================================================")
        appendLog("  Server URL:    http://127.0.0.1:\(port)")
        appendLog("  Health check:  GET  http://127.0.0.1:\(port)/health")
        appendLog("  OpenAI compat: POST http://127.0.0.1:\(port)/v1/chat/completions")
        appendLog("============================================================")
        appendLog("  Configuration:")
        appendLog("    Project ID:  \(projectId.isEmpty ? "NOT SET" : projectId)")
        appendLog("    Location:    \(location)")
        appendLog("    Model:       \(modelId)")
        appendLog("")
        
        if GoogleADCAuthManager.shared.isAdcAvailable {
            appendLog("  [OK] Google ADC 인증 로드됨! (계정: \(GoogleADCAuthManager.shared.userEmail))")
        } else {
            appendLog("  [WARN] Google ADC 인증이 필요합니다. [인증 터미널 명령어 복사] 후 [인증 JSON 파일 로드]를 해주세요.")
        }
        appendLog("")
    }
    
    func startServer() {
        if isRunning {
            appendLog("[INFO] Server is already running on port \(port).")
            return
        }
        saveDotEnv()
        appendLog("[INFO] Starting server on port \(port)...")
        
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            
            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                appendLog("[ERROR] Invalid port number: \(port)")
                return
            }
            
            let newListener = try NWListener(using: params, on: nwPort)
            
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.appendLog("[SERVER] Started listening on http://127.0.0.1:\(self.port)")
                        Task { _ = await self.listVertexModels(refresh: true) }
                    case .failed(let err):
                        self.isRunning = false
                        let desc = err.localizedDescription
                        if desc.contains("Operation not permitted") || desc.contains("error 1") {
                            self.appendLog("[SERVER ERROR] 샌드박스 권한 필요: Xcode의 [Signing & Capabilities]에서 'Incoming Connections (Server)' 체크를 활성화해주세요.")
                        } else {
                            self.appendLog("[SERVER ERROR] Port \(self.port) failed: \(desc)")
                        }
                    case .cancelled:
                        self.isRunning = false
                        self.appendLog("[SERVER] Server cancelled.")
                    default:
                        break
                    }
                }
            }
            
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }
            
            newListener.start(queue: .global(qos: .userInitiated))
            self.listener = newListener
            self.isRunning = true
        } catch {
            self.isRunning = false
            appendLog("[ERROR] Failed to start server: \(error.localizedDescription)")
        }
    }
    
    func stopServer() {
        if !isRunning && listener == nil {
            appendLog("[INFO] Server is already stopped.")
            return
        }
        listener?.cancel()
        listener = nil
        isRunning = false
        appendLog("[SERVER] Server stopped successfully.")
    }
    
    func restartServer() {
        appendLog("[SERVER] Restarting server...")
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startServer()
        }
    }
    
    func saveAndRestart() {
        saveDotEnv()
        appendLog("[CONFIG] Saved settings to .env")
        restartServer()
    }
    
    func runTestConnection() {
        guard isRunning else {
            appendLog("[TEST] Please start the server first.")
            return
        }
        
        isTestingPrompt = true
        testResultPreview = "Requesting Vertex AI via local proxy..."
        appendLog("[TEST] Sending test prompt to http://127.0.0.1:\(port)/v1/chat/completions...")
        
        Task {
            guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let payload: [String: Any] = [
                "model": modelId,
                "messages": [["role": "user", "content": "Respond with 'Vertex Proxy Online!' in 5 words."]],
                "stream": false
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let msg = first["message"] as? [String: Any],
                   let text = msg["content"] as? String {
                    self.testResultPreview = "AI Reply: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
                    self.appendLog("[TEST SUCCESS] \(self.testResultPreview)")
                } else {
                    let errStr = String(data: data, encoding: .utf8) ?? "Unknown Error"
                    self.testResultPreview = "Error: \(errStr)"
                    self.appendLog("[TEST FAILED] \(errStr)")
                }
            } catch {
                self.testResultPreview = "Connection failed: \(error.localizedDescription)"
                self.appendLog("[TEST ERROR] \(error.localizedDescription)")
            }
            self.isTestingPrompt = false
        }
    }
    
    func resolveVertexModel(_ requested: String?) -> String {
        let req = (requested ?? "").trimmingCharacters(in: .whitespaces)
        if !req.isEmpty {
            let aliases = [
                "gpt-4o": "gemini-3.1-pro-preview",
                "gpt-4o-mini": "gemini-3.8-flash",
                "Gemini 3.1 Pro (Vision)": "gemini-3.1-pro-preview"
            ]
            return aliases[req] ?? req
        }
        return self.modelId
    }

    // MARK: - Vertex Endpoint / Auth Helpers (with 401 auto-retry)

    private func vertexEndpointURL(model: String, verb: String) -> URL? {
        let host = (self.location == "global") ? "aiplatform.googleapis.com" : "\(self.location)-aiplatform.googleapis.com"
        let path = "/v1/projects/\(self.projectId)/locations/\(self.location)/publishers/google/models/\(model):\(verb)"
        return URL(string: "https://\(host)\(path)")
    }

    private func generateId(prefix: String) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        var r = ""
        for _ in 0..<24 { r.append(chars.randomElement()!) }
        return prefix + r
    }

    private let maxRateLimitRetries = 4

    // 429 = quota/rate-limit exceeded. Vertex sometimes sends a `Retry-After` header;
    // otherwise back off exponentially (1s, 2s, 4s, 8s), capped at 30s.
    private func rateLimitRetryDelay(forResponse response: HTTPURLResponse, attempt: Int) -> Double {
        if let retryAfterStr = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(retryAfterStr) {
            return min(max(seconds, 0.5), 30)
        }
        return min(pow(2.0, Double(attempt)), 30)
    }

    private func vertexJSONRequest(url: URL, bodyDict: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        func makeRequest(token: String) throws -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            return req
        }

        var token = try await GoogleADCAuthManager.shared.getValidAccessToken()
        var didRefresh401 = false
        var rateLimitAttempt = 0

        while true {
            let (data, response) = try await URLSession.shared.data(for: try makeRequest(token: token))
            guard let httpResp = response as? HTTPURLResponse else {
                throw NSError(domain: "VertexAI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            if httpResp.statusCode == 401 && !didRefresh401 {
                appendLog("[AUTH] Token expired (401). Forcing refresh and retrying...")
                didRefresh401 = true
                token = try await GoogleADCAuthManager.shared.getValidAccessToken(forceRefresh: true)
                continue
            }

            if httpResp.statusCode == 429 && rateLimitAttempt < maxRateLimitRetries {
                let delay = rateLimitRetryDelay(forResponse: httpResp, attempt: rateLimitAttempt)
                rateLimitAttempt += 1
                appendLog("[RATE LIMIT] 429 received. Retrying in \(String(format: "%.1f", delay))s (attempt \(rateLimitAttempt)/\(maxRateLimitRetries))...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            return (data, httpResp)
        }
    }

    private func vertexStreamRequest(url: URL, bodyDict: [String: Any]) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        func makeRequest(token: String) throws -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            return req
        }

        var token = try await GoogleADCAuthManager.shared.getValidAccessToken()
        var didRefresh401 = false
        var rateLimitAttempt = 0

        while true {
            let (bytes, response) = try await URLSession.shared.bytes(for: try makeRequest(token: token))
            guard let httpResp = response as? HTTPURLResponse else {
                throw NSError(domain: "VertexAI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            if httpResp.statusCode == 401 && !didRefresh401 {
                appendLog("[AUTH] Token expired (401) on stream. Forcing refresh and retrying...")
                didRefresh401 = true
                token = try await GoogleADCAuthManager.shared.getValidAccessToken(forceRefresh: true)
                continue
            }

            if httpResp.statusCode == 429 && rateLimitAttempt < maxRateLimitRetries {
                let delay = rateLimitRetryDelay(forResponse: httpResp, attempt: rateLimitAttempt)
                rateLimitAttempt += 1
                appendLog("[RATE LIMIT] 429 received on stream. Retrying in \(String(format: "%.1f", delay))s (attempt \(rateLimitAttempt)/\(maxRateLimitRetries))...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            return (bytes, httpResp)
        }
    }

    // MARK: - Model Catalog + Image Generation (ported from the Windows/Node proxy)

    private lazy var longSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg)
    }()

    func classifyModel(_ id: String) -> String {
        let s = id.lowercased()
        if s.hasPrefix("automl") { return "other" }
        if s.hasPrefix("imagen") || s.range(of: "-image(-|$)", options: .regularExpression) != nil || s.contains("nano-banana") { return "image" }
        if s.hasPrefix("veo") { return "video" }
        if s.contains("embedding") { return "embedding" }
        if s.contains("tts") || s.hasPrefix("chirp") || s.contains("lyria") || s.contains("native-audio") { return "audio" }
        if s.hasPrefix("gemini") || s.hasPrefix("gemma") || s.hasPrefix("gpt-") { return "chat" }
        return "other"
    }

    func supportsThinkingLevel(_ id: String) -> Bool { id.lowercased().contains("gemini-3") }
    func isImagenModel(_ id: String) -> Bool { id.lowercased().hasPrefix("imagen") }
    func isImageModel(_ id: String) -> Bool { classifyModel(id) == "image" }

    private func vertexHost(_ loc: String) -> String {
        (loc.isEmpty || loc == "global") ? "aiplatform.googleapis.com" : "\(loc)-aiplatform.googleapis.com"
    }

    // Generic authenticated JSON call with one 401 refresh retry. Returns (status, parsed JSON object).
    private func vertexRaw(method: String, host: String, path: String, body: [String: Any]?) async throws -> (Int, [String: Any]) {
        var forceRefresh = false
        while true {
            let token = try await GoogleADCAuthManager.shared.getValidAccessToken(forceRefresh: forceRefresh)
            guard let url = URL(string: "https://\(host)\(path)") else {
                throw NSError(domain: "Proxy", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Vertex URL"])
            }
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(projectId, forHTTPHeaderField: "x-goog-user-project")
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await longSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            if status == 401 && !forceRefresh {
                forceRefresh = true
                continue
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                ?? ["raw": String(decoding: data.prefix(500), as: UTF8.self)]
            return (status, obj)
        }
    }

    private func errorMessage(_ data: [String: Any], fallback: String) -> String {
        ((data["error"] as? [String: Any])?["message"] as? String) ?? fallback
    }

    private let fallbackModels = [
        "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
        "gemini-3-pro-image-preview", "gemini-2.5-flash-image",
        "imagen-4.0-generate-001", "imagen-4.0-fast-generate-001", "imagen-4.0-ultra-generate-001", "imagen-3.0-generate-002",
        "text-embedding-005", "gemini-embedding-001"
    ]
    private var modelCatalogIds: [String]?
    private var modelCatalogAt = Date.distantPast

    // Live Google publisher model catalog (1 h cache). Only serverless, API-callable models are listed.
    func listVertexModels(refresh: Bool = false) async -> [String] {
        if !refresh, let ids = modelCatalogIds, Date().timeIntervalSince(modelCatalogAt) < 3600 { return ids }
        var ids = Set<String>()
        var pageToken = ""
        do {
            for _ in 0..<20 {
                var path = "/v1beta1/publishers/google/models?pageSize=200"
                if !pageToken.isEmpty, let enc = pageToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    path += "&pageToken=\(enc)"
                }
                let (status, data) = try await vertexRaw(method: "GET", host: "us-central1-aiplatform.googleapis.com", path: path, body: nil)
                guard status == 200 else {
                    throw NSError(domain: "VertexAI", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(errorMessage(data, fallback: "catalog request failed"))"])
                }
                for m in (data["publisherModels"] as? [[String: Any]]) ?? [] {
                    let id = String(((m["name"] as? String) ?? "").split(separator: "/").last ?? "")
                    if id.isEmpty { continue }
                    if m["openSourceCategory"] != nil && !id.lowercased().hasSuffix("-maas") { continue }
                    ids.insert(id)
                }
                pageToken = (data["nextPageToken"] as? String) ?? ""
                if pageToken.isEmpty { break }
            }
        } catch {
            appendLog("[MODELS] Live model list failed, using fallback list: \(error.localizedDescription)")
        }
        if ids.isEmpty { return fallbackModels }
        let list = ids.sorted()
        modelCatalogIds = list
        modelCatalogAt = Date()
        var shown = list.filter { classifyModel($0) != "other" }
        if !modelId.isEmpty && !shown.contains(modelId) { shown.insert(modelId, at: 0) }
        availableModels = shown
        appendLog("[MODELS] Loaded \(list.count) models from Vertex AI catalog")
        return list
    }

    private func handleModelsRequest(_ connection: NWConnection, queryItems: [URLQueryItem]) {
        let wanted = queryItems.first(where: { $0.name == "type" })?.value?.split(separator: ",").map(String.init)
        let refresh = queryItems.contains(where: { $0.name == "refresh" })
        Task {
            let ids = await self.listVertexModels(refresh: refresh)
            var all: [String] = []
            for m in [self.modelId] + ids + ["gpt-4o", "gpt-4o-mini"] where !m.isEmpty && !all.contains(m) { all.append(m) }
            var items: [[String: Any]] = []
            for id in all {
                let type = self.classifyModel(self.resolveVertexModel(id))
                if let wanted = wanted { if !wanted.contains(type) { continue } } else if type == "other" { continue }
                let isImagen = self.isImagenModel(id)
                items.append([
                    "id": id, "object": "model", "created": 1715385600, "owned_by": "google",
                    "permission": [], "root": id, "parent": NSNull(),
                    "type": type,
                    "input_modalities": (type == "chat" || type == "image") ? ["text", "image"] : ["text"],
                    "output_modalities": type == "image" ? ["image", "text"] : type == "video" ? ["video"] : type == "audio" ? ["audio"] : ["text"],
                    "capabilities": [
                        "vision": type == "chat" || (type == "image" && !isImagen),
                        "reasoning": type == "chat" && id.lowercased().range(of: "gemini-(2\\.5|3)", options: .regularExpression) != nil,
                        "tool_use": type == "chat",
                        "json_mode": type == "chat",
                        "image_generation": type == "image"
                    ]
                ])
            }
            let payload: [String: Any] = ["object": "list", "data": items]
            if let data = try? JSONSerialization.data(withJSONObject: payload), let str = String(data: data, encoding: .utf8) {
                self.sendJson(connection, status: 200, json: str)
            } else {
                self.sendError(connection, status: 500, message: "Failed to encode model list")
            }
        }
    }

    // MARK: Image helpers

    private let imageAspectRatios: [String: Double] = [
        "1:1": 1, "2:3": 2.0 / 3, "3:2": 1.5, "3:4": 3.0 / 4, "4:3": 4.0 / 3,
        "4:5": 0.8, "5:4": 1.25, "9:16": 9.0 / 16, "16:9": 16.0 / 9, "21:9": 21.0 / 9
    ]

    private func sizeToAspectRatio(_ size: String?, explicit: String?) -> String {
        if let e = explicit, imageAspectRatios[e] != nil { return e }
        guard let size = size else { return "1:1" }
        let parts = size.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h > 0 else { return "1:1" }
        let r = w / h
        return imageAspectRatios.min(by: { abs($0.value - r) < abs($1.value - r) })?.key ?? "1:1"
    }

    private var imageSignatureCache: [String: String] = [:]
    private var imageSignatureOrder: [String] = []

    private func imageKey(_ b64: String) -> String {
        Insecure.SHA1.hash(data: Data(b64.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func rememberImageSignature(_ b64: String, _ sig: String) {
        let key = imageKey(b64)
        if imageSignatureCache[key] == nil { imageSignatureOrder.append(key) }
        imageSignatureCache[key] = sig
        while imageSignatureOrder.count > 500 {
            imageSignatureCache.removeValue(forKey: imageSignatureOrder.removeFirst())
        }
    }

    private let imageSafetySettings: [[String: String]] = [
        "HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_SEXUALLY_EXPLICIT",
        "HARM_CATEGORY_DANGEROUS_CONTENT", "HARM_CATEGORY_CIVIC_INTEGRITY"
    ].map { ["category": $0, "threshold": "BLOCK_NONE"] }

    // Optional client options a model may reject with 400: dropped and retried instead of failing.
    private let optionalImageFields: [[String]] = [
        ["tools"],
        ["generationConfig", "mediaResolution"],
        ["generationConfig", "thinkingConfig"],
        ["generationConfig", "imageConfig", "imageOutputOptions"],
        ["generationConfig", "imageConfig", "personGeneration"],
        ["generationConfig", "imageConfig", "imageSize"],
        ["generationConfig", "maxOutputTokens"]
    ]

    private func hasPath(_ o: [String: Any], _ path: ArraySlice<String>) -> Bool {
        guard let k = path.first, let v = o[k] else { return false }
        if path.count == 1 { return true }
        guard let child = v as? [String: Any] else { return false }
        return hasPath(child, path.dropFirst())
    }

    private func deletePath(_ o: inout [String: Any], _ path: ArraySlice<String>) {
        guard let k = path.first else { return }
        if path.count == 1 { o.removeValue(forKey: k); return }
        guard var child = o[k] as? [String: Any] else { return }
        deletePath(&child, path.dropFirst())
        o[k] = child
    }

    private func rejectedImageField(_ body: [String: Any], message: String) -> [String]? {
        for path in optionalImageFields where hasPath(body, path[...]) {
            let name = path[path.count - 1]
            let snake = name.map { $0.isUppercase ? "_" + $0.lowercased() : String($0) }.joined()
            if message.contains(name) || message.contains(snake) { return path }
        }
        let guesses: [(String, [String])] = [
            ("search|grounding|tool", ["tools"]),
            ("thinking", ["generationConfig", "thinkingConfig"]),
            ("media.?resolution", ["generationConfig", "mediaResolution"]),
            ("image.?size|resolution", ["generationConfig", "imageConfig", "imageSize"]),
            ("mime|output.?format|output.?options", ["generationConfig", "imageConfig", "imageOutputOptions"]),
            ("person", ["generationConfig", "imageConfig", "personGeneration"])
        ]
        for (pattern, path) in guesses {
            if message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil && hasPath(body, path[...]) { return path }
        }
        return nil
    }

    private func buildImageGenerationConfig(model: String, ar: String, vertex: [String: Any]?) -> [String: Any] {
        let vgc = (vertex?["generationConfig"] as? [String: Any]) ?? [:]
        var gc: [String: Any] = ["responseModalities": ["TEXT", "IMAGE"]]
        if let rm = vgc["responseModalities"] as? [String], rm.contains("IMAGE") { gc["responseModalities"] = rm }
        if let mot = (vgc["maxOutputTokens"] as? NSNumber)?.intValue, mot > 0 { gc["maxOutputTokens"] = mot }
        if let mr = vgc["mediaResolution"] as? String, !mr.isEmpty { gc["mediaResolution"] = mr }
        if let tc = vgc["thinkingConfig"] as? [String: Any], supportsThinkingLevel(model) { gc["thinkingConfig"] = tc }
        let vic = (vgc["imageConfig"] as? [String: Any]) ?? [:]
        var ic: [String: Any] = [:]
        if let a = vic["aspectRatio"] as? String, imageAspectRatios[a] != nil { ic["aspectRatio"] = a } else { ic["aspectRatio"] = ar }
        if let sz = vic["imageSize"] as? String, ["1K", "2K", "4K"].contains(sz) { ic["imageSize"] = sz }
        if let opts = vic["imageOutputOptions"] as? [String: Any], opts["mimeType"] != nil { ic["imageOutputOptions"] = opts }
        if let pg = vic["personGeneration"] as? String, !pg.isEmpty { ic["personGeneration"] = pg }
        gc["imageConfig"] = ic
        return gc
    }

    struct GeneratedImage { let b64: String; let mimeType: String }
    struct ImageResult { var images: [GeneratedImage] = []; var text = ""; var thoughts = ""; var dropped: [String] = [] }

    private func generateImages(model: String, prompt: String, n: Int, size: String?, aspectRatio: String?,
                                inputImages: [[String: Any]], extra: [String: Any], contents: [[String: Any]]?,
                                systemInstruction: String?, vertex: [String: Any]?) async throws -> ImageResult {
        let ar = sizeToAspectRatio(size, explicit: aspectRatio)
        let count = max(1, min(4, n))

        if isImagenModel(model) {
            let loc = (location == "global") ? "us-central1" : location
            var parameters: [String: Any] = ["sampleCount": count, "aspectRatio": ar]
            for (k, v) in extra { parameters[k] = v }
            let (status, data) = try await vertexRaw(method: "POST", host: vertexHost(loc),
                path: "/v1/projects/\(projectId)/locations/\(loc)/publishers/google/models/\(model):predict",
                body: ["instances": [["prompt": prompt]], "parameters": parameters])
            guard status == 200 else {
                throw NSError(domain: "VertexAI", code: status, userInfo: [NSLocalizedDescriptionKey: errorMessage(data, fallback: "Imagen HTTP \(status)")])
            }
            var result = ImageResult()
            for p in (data["predictions"] as? [[String: Any]]) ?? [] {
                if let b64 = p["bytesBase64Encoded"] as? String {
                    result.images.append(GeneratedImage(b64: b64, mimeType: (p["mimeType"] as? String) ?? "image/png"))
                }
            }
            if result.images.isEmpty {
                throw NSError(domain: "VertexAI", code: 400, userInfo: [NSLocalizedDescriptionKey: "Imagen returned no images (likely blocked by safety filters)."])
            }
            return result
        }

        var body: [String: Any] = [
            "contents": contents ?? [["role": "user", "parts": inputImages + [["text": prompt]]]],
            "generationConfig": buildImageGenerationConfig(model: model, ar: ar, vertex: vertex),
            "safetySettings": imageSafetySettings
        ]
        let vTools = (vertex?["tools"] as? [[String: Any]]) ?? []
        let searchTools = vTools.filter { $0["googleSearch"] != nil }
        if !searchTools.isEmpty { body["tools"] = searchTools.map { ["googleSearch": $0["googleSearch"] ?? [:]] } }
        if let sys = systemInstruction, !sys.isEmpty { body["systemInstruction"] = ["role": "system", "parts": [["text": sys]]] }
        var loc = location
        if let l = vertex?["location"] as? String, l.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil { loc = l }

        var result = ImageResult()
        if vertex?["celebrityGeneration"] != nil { result.dropped.append("celebrityGeneration (no Vertex field)") }
        if vTools.contains(where: { $0["googleSearch"] == nil }) { result.dropped.append("tools other than googleSearch") }

        for _ in 0..<count {
            var status = 0
            var data: [String: Any] = [:]
            var failures = 0
            for _ in 0..<9 {
                do {
                    (status, data) = try await vertexRaw(method: "POST", host: vertexHost(loc),
                        path: "/v1/projects/\(projectId)/locations/\(loc)/publishers/google/models/\(model):generateContent", body: body)
                } catch {
                    if failures == 0 {
                        failures += 1
                        appendLog("[IMAGES] \(error.localizedDescription), retrying once")
                        continue
                    }
                    throw error
                }
                if status == 400, let path = rejectedImageField(body, message: errorMessage(data, fallback: "")) {
                    deletePath(&body, path[...])
                    result.dropped.append(path.joined(separator: "."))
                    appendLog("[IMAGES] Vertex rejected \(path.joined(separator: ".")) for \(model)")
                    continue
                }
                let backoff: [Double] = status == 429 ? [5, 15, 30] : (status >= 500 ? [3] : [])
                if failures < backoff.count {
                    let wait = backoff[failures]
                    failures += 1
                    appendLog("[IMAGES] HTTP \(status) - retry \(failures)/\(backoff.count) in \(Int(wait))s")
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                break
            }
            guard status == 200 else {
                throw NSError(domain: "VertexAI", code: status, userInfo: [NSLocalizedDescriptionKey: errorMessage(data, fallback: "Gemini image HTTP \(status)")])
            }
            let parts = (((data["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for p in parts {
                let isThought = (p["thought"] as? Bool) == true
                if let inline = p["inlineData"] as? [String: Any], let b64 = inline["data"] as? String {
                    if isThought { continue }
                    result.images.append(GeneratedImage(b64: b64, mimeType: (inline["mimeType"] as? String) ?? "image/png"))
                    if let sig = (p["thoughtSignature"] as? String) ?? (p["thought_signature"] as? String) { rememberImageSignature(b64, sig) }
                } else if let t = p["text"] as? String {
                    if isThought { result.thoughts += t } else { result.text += t }
                }
            }
        }
        if !result.dropped.isEmpty { appendLog("[IMAGES] Options not applied for \(model): \(result.dropped.joined(separator: ", "))") }
        if result.images.isEmpty {
            throw NSError(domain: "VertexAI", code: 400, userInfo: [NSLocalizedDescriptionKey: result.text.isEmpty ? "Model returned no image." : result.text])
        }
        return result
    }

    private func sendImageError(_ connection: NWConnection, _ error: Error) {
        let code = (error as NSError).code
        sendError(connection, status: (400..<600).contains(code) ? code : 500, message: error.localizedDescription)
    }

    // POST /v1/images/generations (OpenAI-compatible; Gemini image models also accept input images for edits)
    private func handleImageGenerations(_ connection: NWConnection, body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendError(connection, status: 400, message: "Invalid JSON body")
            return
        }
        guard let prompt = json["prompt"] as? String, !prompt.isEmpty else {
            sendError(connection, status: 400, message: "prompt is required")
            return
        }
        let requested = (json["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "imagen-4.0-generate-001"
        let model = resolveVertexModel(requested)
        let n = (json["n"] as? NSNumber)?.intValue ?? 1
        let size = json["size"] as? String
        let responseFormat = json["response_format"] as? String

        Task {
            do {
                var rawImages: [Any] = []
                if let arr = json["images"] as? [Any] { rawImages += arr } else if let one = json["images"] { rawImages.append(one) }
                if let arr = json["image"] as? [Any] { rawImages += arr } else if let one = json["image"] { rawImages.append(one) }
                var inputImages: [[String: Any]] = []
                for u in rawImages {
                    let s = (u as? String) ?? ((u as? [String: Any])?["url"] as? String) ?? ((u as? [String: Any])?["image_url"] as? String)
                    if let s = s, let part = await self.resolveImageUrlToPart(s) { inputImages.append(part) }
                }
                self.appendLog("[IMAGES] model=\(model) n=\(n) size=\(size ?? "-") inputImages=\(inputImages.count)")
                let result = try await self.generateImages(model: model, prompt: prompt, n: n, size: size,
                    aspectRatio: json["aspect_ratio"] as? String, inputImages: inputImages,
                    extra: (json["parameters"] as? [String: Any]) ?? [:], contents: nil, systemInstruction: nil,
                    vertex: json["vertex"] as? [String: Any])
                let data: [[String: Any]] = result.images.map { img in
                    var item: [String: Any] = responseFormat == "url" ? ["url": "data:\(img.mimeType);base64,\(img.b64)"] : ["b64_json": img.b64]
                    if !result.text.isEmpty { item["revised_prompt"] = result.text }
                    return item
                }
                let out: [String: Any] = ["created": Int(Date().timeIntervalSince1970), "data": data]
                let outData = try JSONSerialization.data(withJSONObject: out)
                self.sendJson(connection, status: 200, json: String(decoding: outData, as: UTF8.self))
            } catch {
                self.appendLog("[IMAGES] Error: \(error.localizedDescription)")
                self.sendImageError(connection, error)
            }
        }
    }

    // Image model selected through /v1/chat/completions: result is markdown `data:` image(s).
    private func handleImageModelChat(_ connection: NWConnection, jsonReq: [String: Any], messages: [[String: Any]], model: String, stream: Bool) {
        Task {
            do {
                func items(of content: Any?) -> [[String: Any]] {
                    if let s = content as? String { return [["type": "text", "text": s]] }
                    return (content as? [[String: Any]]) ?? []
                }
                func imageUrl(of item: [String: Any]) -> String? {
                    if let obj = item["image_url"] as? [String: Any] { return obj["url"] as? String }
                    return item["image_url"] as? String
                }

                let lastUser = messages.last(where: { ($0["role"] as? String) == "user" }) ?? [:]
                var prompt = ""
                var inputImages: [[String: Any]] = []
                for c in items(of: lastUser["content"]) {
                    if (c["type"] as? String) == "text", let t = c["text"] as? String {
                        prompt += (prompt.isEmpty ? "" : "\n") + t
                    } else if (c["type"] as? String) == "image_url", !self.isImagenModel(model),
                              let u = imageUrl(of: c), let part = await self.resolveImageUrlToPart(u) {
                        inputImages.append(part)
                    }
                }

                var contents: [[String: Any]]? = nil
                var systemInstruction: String? = nil
                if !self.isImagenModel(model) {
                    var turns: [[String: Any]] = []
                    var sys: [String] = []
                    let mdImage = try NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\((data:([^;]+);base64,([A-Za-z0-9+/=]+))\\)")
                    for m in messages {
                        let role = (m["role"] as? String) ?? "user"
                        var parts: [[String: Any]] = []
                        if role == "system" || role == "developer" {
                            sys.append(items(of: m["content"]).compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
                            continue
                        }
                        for c in items(of: m["content"]) {
                            if (c["type"] as? String) == "image_url" {
                                if let u = imageUrl(of: c), let part = await self.resolveImageUrlToPart(u) { parts.append(part) }
                            } else if (c["type"] as? String) == "text", let text = c["text"] as? String, !text.isEmpty {
                                let ns = text as NSString
                                var last = 0
                                for mm in mdImage.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                                    let before = ns.substring(with: NSRange(location: last, length: mm.range.location - last)).trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !before.isEmpty { parts.append(["text": before]) }
                                    let mime = ns.substring(with: mm.range(at: 2))
                                    let b64 = ns.substring(with: mm.range(at: 3))
                                    var img: [String: Any] = ["inlineData": ["mimeType": self.normalizeImageMime(mime), "data": b64]]
                                    if role == "assistant" {
                                        img["thoughtSignature"] = self.imageSignatureCache[self.imageKey(b64)] ?? "skip_thought_signature_validator"
                                    }
                                    parts.append(img)
                                    last = mm.range.location + mm.range.length
                                }
                                let rest = ns.substring(from: last).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !rest.isEmpty { parts.append(["text": rest]) }
                            }
                        }
                        if !parts.isEmpty { turns.append(["role": role == "assistant" ? "model" : "user", "parts": parts]) }
                    }
                    contents = turns
                    let joined = sys.filter { !$0.isEmpty }.joined(separator: "\n")
                    systemInstruction = joined.isEmpty ? nil : joined
                    self.appendLog("[V1/CHAT image] \(turns.count) turns")
                }

                let result = try await self.generateImages(model: model, prompt: prompt,
                    n: (jsonReq["n"] as? NSNumber)?.intValue ?? 1, size: jsonReq["size"] as? String,
                    aspectRatio: jsonReq["aspect_ratio"] as? String, inputImages: inputImages, extra: [:],
                    contents: contents, systemInstruction: systemInstruction, vertex: jsonReq["vertex"] as? [String: Any])

                var chunks: [String] = []
                if !result.text.isEmpty { chunks.append(result.text) }
                for (i, img) in result.images.enumerated() { chunks.append("![image \(i + 1)](data:\(img.mimeType);base64,\(img.b64))") }
                let content = chunks.joined(separator: "\n\n")
                let id = "chatcmpl-\(Int(Date().timeIntervalSince1970 * 1000))"
                let created = Int(Date().timeIntervalSince1970)

                if stream {
                    var delta: [String: Any] = ["role": "assistant", "content": content]
                    if !result.thoughts.isEmpty { delta["reasoning_content"] = result.thoughts }
                    var first: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                        "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]]
                    if !result.dropped.isEmpty { first["vertex_dropped"] = result.dropped }
                    let fin: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                        "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]]]
                    let a = String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self)
                    let b = String(decoding: try JSONSerialization.data(withJSONObject: fin), as: UTF8.self)
                    let payload = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\n\r\ndata: \(a)\n\ndata: \(b)\n\ndata: [DONE]\n\n"
                    connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in self.finishConnection(connection) })
                } else {
                    var message: [String: Any] = ["role": "assistant", "content": content]
                    if !result.thoughts.isEmpty { message["reasoning_content"] = result.thoughts }
                    var out: [String: Any] = ["id": id, "object": "chat.completion", "created": created, "model": model,
                        "choices": [["index": 0, "message": message, "finish_reason": "stop"]],
                        "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]]
                    if !result.dropped.isEmpty { out["vertex_dropped"] = result.dropped }
                    self.sendJson(connection, status: 200, json: String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
                }
                self.appendLog("[V1/CHAT image] Done. Model: \(model), images: \(result.images.count)")
            } catch {
                self.appendLog("[V1/CHAT image] Error: \(error.localizedDescription)")
                self.sendImageError(connection, error)
            }
        }
    }

    // MARK: - Tool Schema Sanitization / tool_choice

    private func sanitizeToolSchema(_ schema: [String: Any]) -> [String: Any] {
        let allowedKeys = ["type", "properties", "required", "items", "description", "enum", "format"]
        var result: [String: Any] = [:]
        for key in allowedKeys {
            guard let val = schema[key] else { continue }
            if key == "properties", let props = val as? [String: Any] {
                var newProps: [String: Any] = [:]
                for (propKey, propVal) in props {
                    if let propDict = propVal as? [String: Any] {
                        newProps[propKey] = sanitizeToolSchema(propDict)
                    } else {
                        newProps[propKey] = propVal
                    }
                }
                result["properties"] = newProps
            } else if key == "items", let itemsDict = val as? [String: Any] {
                result["items"] = sanitizeToolSchema(itemsDict)
            } else {
                result[key] = val
            }
        }
        if result["type"] == nil && result["properties"] != nil {
            result["type"] = "object"
        }
        return result
    }

    private func buildFunctionDeclarations(from tools: [[String: Any]]) -> [[String: Any]] {
        var decls: [[String: Any]] = []
        for t in tools {
            guard (t["type"] as? String) == "function", var fn = t["function"] as? [String: Any] else { continue }
            if let params = fn["parameters"] as? [String: Any] {
                fn["parameters"] = sanitizeToolSchema(params)
            }
            decls.append(fn)
        }
        return decls
    }

    private func toolConfig(fromToolChoice toolChoice: Any?) -> [String: Any]? {
        guard let toolChoice = toolChoice else { return nil }
        if let s = toolChoice as? String {
            switch s {
            case "none": return ["functionCallingConfig": ["mode": "NONE"]]
            case "auto": return ["functionCallingConfig": ["mode": "AUTO"]]
            case "required": return ["functionCallingConfig": ["mode": "ANY"]]
            default: return nil
            }
        }
        if let obj = toolChoice as? [String: Any], (obj["type"] as? String) == "function",
           let fn = obj["function"] as? [String: Any], let fname = fn["name"] as? String {
            return ["functionCallingConfig": ["mode": "ANY", "allowedFunctionNames": [fname]]]
        }
        return nil
    }

    // MARK: - Multimodal Image Resolution (data URI / raw base64 / http(s) fetch)

    private let maxImageFetchBytes = 20 * 1024 * 1024
    private let imageFetchTimeoutSeconds: TimeInterval = 45

    private func normalizeImageMime(_ mime: String?) -> String {
        var m = (mime ?? "image/png").split(separator: ";").first.map(String.init) ?? "image/png"
        m = m.trimmingCharacters(in: .whitespaces).lowercased()
        if m == "image/jpg" { m = "image/jpeg" }
        return m.isEmpty ? "image/png" : m
    }

    private func sniffImageMime(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return "image/jpeg" }
        if bytes.count >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "image/png" }
        if bytes.count >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return "image/gif" }
        if bytes.count >= 12,
           let riff = String(bytes: bytes[0..<4], encoding: .ascii),
           let webp = String(bytes: bytes[8..<12], encoding: .ascii),
           riff == "RIFF", webp == "WEBP" {
            return "image/webp"
        }
        return nil
    }

    private func parseDataUriImagePart(_ urlString: String) -> [String: Any]? {
        guard urlString.hasPrefix("data:"), let semiRange = urlString.range(of: ";base64,") else { return nil }
        let mimePart = String(urlString[urlString.index(urlString.startIndex, offsetBy: 5)..<semiRange.lowerBound])
        let dataPart = String(urlString[semiRange.upperBound...]).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        guard !dataPart.isEmpty else { return nil }
        return ["inlineData": ["mimeType": normalizeImageMime(mimePart), "data": dataPart]]
    }

    private func tryRawBase64ImagePart(_ s: String) -> [String: Any]? {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
        guard cleaned.count >= 80 else { return nil }
        let lower = cleaned.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") { return nil }
        let base64Charset = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard cleaned.unicodeScalars.allSatisfy({ base64Charset.contains($0) }) else { return nil }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return ["inlineData": ["mimeType": sniffImageMime(data) ?? "image/png", "data": cleaned]]
    }

    private func fetchHttpImageAsInlinePart(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString), (url.scheme == "http" || url.scheme == "https") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: imageFetchTimeoutSeconds)
        req.setValue("image/*,application/octet-stream;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else { return nil }
            guard data.count <= maxImageFetchBytes else { return nil }
            var mime = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map(String.init) ?? ""
            mime = mime.trimmingCharacters(in: .whitespaces).lowercased()
            mime = mime.hasPrefix("image/") ? normalizeImageMime(mime) : (sniffImageMime(data) ?? "image/png")
            return ["inlineData": ["mimeType": mime, "data": data.base64EncodedString()]]
        } catch {
            return nil
        }
    }

    private func resolveImageUrlToPart(_ urlString: String) async -> [String: Any]? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = tryRawBase64ImagePart(trimmed) { return raw }
        if let dataUri = parseDataUriImagePart(trimmed) { return dataUri }
        return await fetchHttpImageAsInlinePart(trimmed)
    }

    // MARK: - OpenAI messages[] -> Gemini contents[] (shared by /v1/chat/completions and /v1/responses)

    private func buildGeminiContents(from messages: [[String: Any]]) async -> (contents: [[String: Any]], systemText: String, hasInlinedImages: Bool, imageLoadError: String?) {
        var contents: [[String: Any]] = []
        var systemText = ""
        var hasInlinedImages = false
        var imageUrlsSeen = 0
        var imageUrlsEmbedded = 0

        for msg in messages {
            let role = (msg["role"] as? String) ?? "user"
            var msgText = ""
            var imageParts: [[String: Any]] = []

            if let contentArray = msg["content"] as? [[String: Any]] {
                for c in contentArray {
                    if let t = c["text"] as? String { msgText += (msgText.isEmpty ? "" : "\n") + t }
                    if let type = c["type"] as? String, type == "image_url",
                       let imgObj = c["image_url"] as? [String: Any],
                       let urlStr = imgObj["url"] as? String {
                        imageUrlsSeen += 1
                        if let inlined = await resolveImageUrlToPart(urlStr) {
                            imageParts.append(inlined)
                            imageUrlsEmbedded += 1
                            hasInlinedImages = true
                        }
                    }
                }
            } else if let contentStr = msg["content"] as? String {
                msgText = contentStr
            }

            if role == "system" || role == "developer" {
                systemText += (systemText.isEmpty ? "" : "\n\n") + msgText
                continue
            }

            if role == "user" {
                var parts: [[String: Any]] = []
                if !msgText.isEmpty { parts.append(["text": msgText]) }
                parts.append(contentsOf: imageParts)
                if parts.isEmpty { parts.append(["text": " "]) }
                contents.append(["role": "user", "parts": parts])
            } else if role == "assistant" {
                var parts: [[String: Any]] = []
                if !msgText.isEmpty { parts.append(["text": msgText]) }

                if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        if let funcObj = tc["function"] as? [String: Any],
                           let funcName = funcObj["name"] as? String {
                            let argsStr = (funcObj["arguments"] as? String) ?? "{}"
                            let argsObj = (try? JSONSerialization.jsonObject(with: argsStr.data(using: .utf8) ?? Data())) ?? [:]
                            let callId = (tc["id"] as? String) ?? ""

                            var callPart: [String: Any] = [
                                "functionCall": ["name": funcName, "args": argsObj]
                            ]

                            let stored = ToolCallLRUCache.shared.get(callId)
                            let signature = stored?.signature ?? ToolCallLRUCache.shared.getSignatureByName(funcName)
                            if let sig = signature {
                                callPart["thought_signature"] = sig
                            }
                            parts.append(callPart)
                        }
                    }
                }
                if !parts.isEmpty { contents.append(["role": "model", "parts": parts]) }
            } else if role == "tool" {
                let toolCallId = (msg["tool_call_id"] as? String) ?? ""
                let stored = ToolCallLRUCache.shared.get(toolCallId)
                let funcName = (msg["name"] as? String) ?? stored?.name ?? "unknown_function"

                var parsedResp: Any = msgText
                if let d = msgText.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) {
                    parsedResp = o
                }

                let respPart: [String: Any] = [
                    "functionResponse": [
                        "name": funcName,
                        "response": (parsedResp is [String: Any]) ? parsedResp : ["result": parsedResp]
                    ]
                ]

                if var last = contents.last, (last["role"] as? String) == "user" {
                    var pList = (last["parts"] as? [[String: Any]]) ?? []
                    pList.append(respPart)
                    last["parts"] = pList
                    contents[contents.count - 1] = last
                } else {
                    contents.append(["role": "user", "parts": [respPart]])
                }
            }
        }

        if imageUrlsSeen > imageUrlsEmbedded {
            return (contents: [], systemText: "", hasInlinedImages: false, imageLoadError: "이미지를 불러올 수 없습니다. (Could not load one or more images)")
        }

        if hasInlinedImages && !systemText.contains("VISION SYSTEM") {
            systemText = "VISION SYSTEM ACTIVATED: You can see images.\n" + systemText
        }

        return (contents: contents, systemText: systemText, hasInlinedImages: hasInlinedImages, imageLoadError: nil)
    }

    // MARK: - HTTP Connection Handling
    func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        
        func readNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    buffer.append(data)
                    
                    if let separatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = buffer.subdata(in: 0..<separatorRange.lowerBound)
                        let bodyData = buffer.subdata(in: separatorRange.upperBound..<buffer.count)
                        
                        guard let headerString = String(data: headerData, encoding: .utf8),
                              let requestLine = headerString.components(separatedBy: "\r\n").first else {
                            self.sendSimpleResponse(connection, status: 400, body: "Bad Request")
                            return
                        }
                        
                        let reqParts = requestLine.components(separatedBy: " ")
                        guard reqParts.count >= 2 else {
                            self.sendSimpleResponse(connection, status: 400, body: "Bad Request")
                            return
                        }
                        
                        let method = reqParts[0]
                        let path = reqParts[1]
                        
                        var contentLength = 0
                        for line in headerString.components(separatedBy: "\r\n") {
                            let lower = line.lowercased()
                            if lower.hasPrefix("content-length:") {
                                let valStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                                contentLength = Int(valStr) ?? 0
                            }
                        }
                        
                        if bodyData.count >= contentLength {
                            let finalBody = bodyData.prefix(contentLength)
                            self.routeRequest(connection: connection, method: method, path: path, body: Data(finalBody))
                        } else {
                            self.readRemaining(connection: connection, buffer: buffer, expectedTotal: separatorRange.upperBound + contentLength)
                        }
                        return
                    }
                }
                if isComplete {
                    connection.cancel()
                } else if error == nil {
                    readNext()
                }
            }
        }
        readNext()
    }
    
    private func readRemaining(connection: NWConnection, buffer: Data, expectedTotal: Int) {
        var currentBuffer = buffer
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data {
                    currentBuffer.append(data)
                    if currentBuffer.count >= expectedTotal {
                        if let separatorRange = currentBuffer.range(of: Data("\r\n\r\n".utf8)),
                           let headerString = String(data: currentBuffer.subdata(in: 0..<separatorRange.lowerBound), encoding: .utf8),
                           let requestLine = headerString.components(separatedBy: "\r\n").first {
                            let reqParts = requestLine.components(separatedBy: " ")
                            if reqParts.count >= 2 {
                                let bodyData = currentBuffer.subdata(in: separatorRange.upperBound..<currentBuffer.count)
                                self.routeRequest(connection: connection, method: reqParts[0], path: reqParts[1], body: bodyData)
                                return
                            }
                        }
                    }
                }
                if !isComplete && error == nil {
                    readMore()
                }
            }
        }
        readMore()
    }
    
    private func routeRequest(connection: NWConnection, method: String, path rawPath: String, body: Data) {
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let queryItems = URLComponents(string: "http://localhost" + rawPath)?.queryItems ?? []
        let timestamp = ISO8601DateFormatter().string(from: Date())
        appendLog("[\(timestamp)] \(method) \(rawPath)")
        
        if method == "OPTIONS" {
            sendCORS(connection)
            return
        }
        
        if method == "GET" && (path == "/health" || path == "/") {
            let json = """
            {
              "status": "ok",
              "message": "Server is running",
              "timestamp": "\(timestamp)",
              "configured": true,
              "projectId": "\(projectId)",
              "location": "\(location)",
              "model": "\(modelId)"
            }
            """
            sendJson(connection, status: 200, json: json)
            return
        }
        
        if method == "GET" && (path == "/v1/models" || path == "/models") {
            handleModelsRequest(connection, queryItems: queryItems)
            return
        }

        if method == "POST" && path == "/v1/images/generations" {
            handleImageGenerations(connection, body: body)
            return
        }
        
        if method == "POST" && (path == "/chat") {
            handleLegacyChat(connection, body: body)
            return
        }
        
        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            handleChatCompletions(connection, body: body)
            return
        }

        if method == "POST" && path == "/v1/responses" {
            handleResponses(connection, body: body)
            return
        }
        
        sendSimpleResponse(connection, status: 404, body: "{\"error\": \"Not Found\"}")
    }
    
    private func handleLegacyChat(_ connection: NWConnection, body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = json["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            sendError(connection, status: 400, message: "Prompt must be a non-empty string")
            return
        }
        
        Task {
            do {
                guard let url = self.vertexEndpointURL(model: self.modelId, verb: "generateContent") else {
                    throw NSError(domain: "Proxy", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
                }

                let reqPayload: [String: Any] = [
                    "contents": [["role": "user", "parts": [["text": prompt]]]],
                    "generationConfig": ["temperature": 0.9, "maxOutputTokens": 32768]
                ]

                let (data, httpResp) = try await self.vertexJSONRequest(url: url, bodyDict: reqPayload)
                guard (200...299).contains(httpResp.statusCode) else {
                    let errStr = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "VertexAI", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Vertex AI Error: \(errStr)"])
                }

                var reply = "No response generated"
                if let respJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = respJson["candidates"] as? [[String: Any]],
                   let first = candidates.first,
                   let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {
                    reply = text
                }
                
                let outJson = "{\"reply\": \(String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8) ?? "\"\"")}"
                self.sendJson(connection, status: 200, json: outJson)
            } catch {
                self.sendError(connection, status: 500, message: error.localizedDescription)
            }
        }
    }
    
    private func handleChatCompletions(_ connection: NWConnection, body: Data) {
        guard let jsonReq = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = jsonReq["messages"] as? [[String: Any]], !messages.isEmpty else {
            sendError(connection, status: 400, message: "messages is required and must be a non-empty array")
            return
        }
        
        let requestedModel = jsonReq["model"] as? String
        let modelToUse = resolveVertexModel(requestedModel)
        let isStreaming = (jsonReq["stream"] as? Bool) ?? false
        let temperature = jsonReq["temperature"] as? Double ?? 0.9
        let maxTokens = jsonReq["max_tokens"] as? Int ?? 32768
        let tools = jsonReq["tools"] as? [[String: Any]]
        let toolChoice = jsonReq["tool_choice"]

        appendLog("[V1/CHAT] Stream: \(isStreaming), Messages: \(messages.count), Tools: \(tools?.count ?? 0), Model: \(modelToUse)")

        if isImageModel(modelToUse) {
            handleImageModelChat(connection, jsonReq: jsonReq, messages: messages, model: modelToUse, stream: isStreaming)
            return
        }

        Task {
            var sseHeadersSent = false
            do {
                let (contents, systemText, hasInlinedImages, imageLoadError) = await buildGeminiContents(from: messages)
                if let err = imageLoadError {
                    self.sendError(connection, status: 400, message: err)
                    return
                }

                var genConfig: [String: Any] = ["maxOutputTokens": maxTokens]
                let isGemini3Flash = modelToUse.range(of: "^gemini-3\\.\\d+-flash$", options: .regularExpression) != nil
                if !isGemini3Flash {
                    genConfig["temperature"] = temperature
                    genConfig["topP"] = 1
                    genConfig["topK"] = 40
                }
                if !hasInlinedImages && supportsThinkingLevel(modelToUse) {
                    genConfig["thinkingConfig"] = ["thinkingLevel": "high"]
                }

                var baseRequestBody: [String: Any] = [
                    "contents": contents,
                    "generationConfig": genConfig
                ]

                if !systemText.isEmpty {
                    baseRequestBody["systemInstruction"] = ["role": "system", "parts": [["text": systemText]]]
                }

                if let toolList = tools, !toolList.isEmpty {
                    let decls = self.buildFunctionDeclarations(from: toolList)
                    if !decls.isEmpty { baseRequestBody["tools"] = [["functionDeclarations": decls]] }
                    if let tc = self.toolConfig(fromToolChoice: toolChoice) {
                        baseRequestBody["toolConfig"] = tc
                    }
                }

                let verb = isStreaming ? "streamGenerateContent?alt=sse" : "generateContent"
                guard let url = self.vertexEndpointURL(model: modelToUse, verb: verb) else {
                    self.sendError(connection, status: 400, message: "Invalid Vertex Endpoint URL")
                    return
                }

                if isStreaming {
                    // Only commit the client to a 200 SSE response once Vertex has actually
                    // confirmed success (after any 401/429 retries) — sending headers any
                    // earlier risks writing a second, malformed response on error below.
                    let (bytes, httpResp) = try await self.vertexStreamRequest(url: url, bodyDict: baseRequestBody)
                    guard (200...299).contains(httpResp.statusCode) else {
                        throw NSError(domain: "VertexAI", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Vertex API stream returned error"])
                    }

                    let sseHeaders = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache, no-transform\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
                    connection.send(content: sseHeaders.data(using: .utf8), completion: .contentProcessed { _ in })
                    sseHeadersSent = true

                    let streamId = "chatcmpl-\(Date().timeIntervalSince1970)"
                    var hasStreamedToolCall = false
                    
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let jsonStr = trimmed.hasPrefix("data: ") ? String(trimmed.dropFirst(6)) : String(trimmed.dropFirst(5))
                        if jsonStr == "[DONE]" { continue }
                        
                        guard let d = jsonStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let candidates = obj["candidates"] as? [[String: Any]],
                              let firstCand = candidates.first,
                              let contentObj = firstCand["content"] as? [String: Any],
                              let parts = contentObj["parts"] as? [[String: Any]] else {
                            continue
                        }
                        
                        for p in parts {
                            if (p["thought"] as? Bool) == true { continue }
                            
                            if let text = p["text"] as? String {
                                let chunk: [String: Any] = [
                                    "id": streamId,
                                    "object": "chat.completion.chunk",
                                    "created": Int(Date().timeIntervalSince1970),
                                    "model": modelToUse,
                                    "choices": [
                                        ["index": 0, "delta": ["role": "assistant", "content": text], "finish_reason": NSNull()]
                                    ]
                                ]
                                if let chunkData = try? JSONSerialization.data(withJSONObject: chunk),
                                   let str = String(data: chunkData, encoding: .utf8) {
                                    connection.send(content: "data: \(str)\n\n".data(using: .utf8), completion: .contentProcessed { _ in })
                                }
                            }
                            
                            if let fc = p["functionCall"] as? [String: Any],
                               let fName = fc["name"] as? String {
                                hasStreamedToolCall = true
                                let callId = "call_\(UUID().uuidString.prefix(9))"
                                let args = fc["args"] as? [String: Any] ?? [:]
                                let argsStr = String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data(), encoding: .utf8) ?? "{}"
                                let sig = (p["thought_signature"] as? String) ?? (p["thoughtSignature"] as? String)
                                
                                ToolCallLRUCache.shared.set(callId, name: fName, signature: sig)
                                
                                let tcChunk: [String: Any] = [
                                    "id": streamId,
                                    "object": "chat.completion.chunk",
                                    "created": Int(Date().timeIntervalSince1970),
                                    "model": modelToUse,
                                    "choices": [
                                        [
                                            "index": 0,
                                            "delta": [
                                                "role": "assistant",
                                                "tool_calls": [
                                                    ["index": 0, "id": callId, "type": "function", "function": ["name": fName, "arguments": argsStr]]
                                                ]
                                            ],
                                            "finish_reason": NSNull()
                                        ]
                                    ]
                                ]
                                if let tcData = try? JSONSerialization.data(withJSONObject: tcChunk),
                                   let str = String(data: tcData, encoding: .utf8) {
                                    connection.send(content: "data: \(str)\n\n".data(using: .utf8), completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    
                    let finishChunk: [String: Any] = [
                        "id": streamId,
                        "object": "chat.completion.chunk",
                        "created": Int(Date().timeIntervalSince1970),
                        "model": modelToUse,
                        "choices": [
                            ["index": 0, "delta": [:], "finish_reason": hasStreamedToolCall ? "tool_calls" : "stop"]
                        ]
                    ]
                    if let finData = try? JSONSerialization.data(withJSONObject: finishChunk),
                       let finStr = String(data: finData, encoding: .utf8) {
                        connection.send(content: "data: \(finStr)\n\ndata: [DONE]\n\n".data(using: .utf8), completion: .contentProcessed { _ in
                            self.finishConnection(connection)
                        })
                    } else {
                        self.finishConnection(connection)
                    }
                    self.appendLog("[V1/STREAM] Completed successfully. Model: \(modelToUse)")
                } else {
                    let (data, httpResp) = try await self.vertexJSONRequest(url: url, bodyDict: baseRequestBody)
                    guard (200...299).contains(httpResp.statusCode) else {
                        let errStr = String(data: data, encoding: .utf8) ?? ""
                        throw NSError(domain: "VertexAI", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Vertex AI Error: \(errStr)"])
                    }

                    var replyText = ""
                    var toolCalls: [[String: Any]]? = nil
                    
                    if let geminiResp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = geminiResp["candidates"] as? [[String: Any]],
                       let firstCand = candidates.first,
                       let contentObj = firstCand["content"] as? [String: Any],
                       let parts = contentObj["parts"] as? [[String: Any]] {
                        
                        for p in parts {
                            if (p["thought"] as? Bool) == true { continue }
                            if let t = p["text"] as? String { replyText += t }
                            if let fc = p["functionCall"] as? [String: Any], let fName = fc["name"] as? String {
                                let callId = "call_\(UUID().uuidString.prefix(9))"
                                let args = fc["args"] as? [String: Any] ?? [:]
                                let argsStr = String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data(), encoding: .utf8) ?? "{}"
                                let sig = (p["thought_signature"] as? String) ?? (p["thoughtSignature"] as? String)
                                
                                ToolCallLRUCache.shared.set(callId, name: fName, signature: sig)
                                if toolCalls == nil { toolCalls = [] }
                                toolCalls?.append([
                                    "id": callId,
                                    "type": "function",
                                    "function": ["name": fName, "arguments": argsStr]
                                ])
                            }
                        }
                    }
                    
                    var messagePayload: [String: Any] = [
                        "role": "assistant",
                        "content": replyText.isEmpty ? (toolCalls == nil ? "No response generated" : NSNull()) : replyText
                    ]
                    if let tc = toolCalls { messagePayload["tool_calls"] = tc }
                    
                    let openAiResp: [String: Any] = [
                        "id": "chatcmpl-\(Date().timeIntervalSince1970)",
                        "object": "chat.completion",
                        "created": Int(Date().timeIntervalSince1970),
                        "model": modelToUse,
                        "choices": [
                            [
                                "index": 0,
                                "message": messagePayload,
                                "finish_reason": (toolCalls != nil) ? "tool_calls" : "stop"
                            ]
                        ],
                        "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
                    ]
                    
                    let outData = try JSONSerialization.data(withJSONObject: openAiResp)
                    self.sendJson(connection, status: 200, json: String(data: outData, encoding: .utf8) ?? "{}")
                    self.appendLog("[V1/CHAT] Response returned successfully.")
                }
            } catch {
                self.appendLog("[V1/CHAT ERROR] \(error.localizedDescription)")
                if sseHeadersSent {
                    // Headers already committed to 200 SSE — emit the error as an SSE
                    // data event instead of writing a second HTTP response.
                    let errPayload: [String: Any] = ["error": ["message": error.localizedDescription, "type": "api_error"]]
                    if let d = try? JSONSerialization.data(withJSONObject: errPayload), let s = String(data: d, encoding: .utf8) {
                        connection.send(content: "data: \(s)\n\n".data(using: .utf8), completion: .contentProcessed { _ in
                            self.finishConnection(connection)
                        })
                    } else {
                        self.finishConnection(connection)
                    }
                } else {
                    self.sendError(connection, status: 500, message: error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - OpenAI Responses API endpoint: /v1/responses

    private func handleResponses(_ connection: NWConnection, body: Data) {
        guard let jsonReq = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendError(connection, status: 400, message: "Invalid JSON body")
            return
        }

        let requestedModel = jsonReq["model"] as? String
        let modelToUse = resolveVertexModel(requestedModel)
        let instructions = jsonReq["instructions"] as? String
        let input = jsonReq["input"]
        let tools = jsonReq["tools"] as? [[String: Any]]
        let temperature = jsonReq["temperature"] as? Double ?? 0.7
        let maxOutputTokens = jsonReq["max_output_tokens"] as? Int ?? 32768
        let isStreaming = (jsonReq["stream"] as? Bool) ?? false

        // --- Convert Responses API input -> internal messages array ---
        var messages: [[String: Any]] = []
        if let instr = instructions, !instr.isEmpty {
            messages.append(["role": "system", "content": instr])
        }

        if let inputStr = input as? String {
            messages.append(["role": "user", "content": inputStr])
        } else if let inputArr = input as? [[String: Any]] {
            for item in inputArr {
                if let role = item["role"] as? String, ["user", "system", "developer"].contains(role) {
                    let normalizedRole = (role == "developer") ? "system" : role
                    if let contentStr = item["content"] as? String {
                        messages.append(["role": normalizedRole, "content": contentStr])
                    } else if let contentArr = item["content"] as? [[String: Any]] {
                        var parts: [[String: Any]] = []
                        for part in contentArr {
                            let type = part["type"] as? String
                            if type == "input_text", let text = part["text"] as? String {
                                parts.append(["type": "text", "text": text])
                            } else if type == "input_image" {
                                var url: String? = nil
                                if let imgObj = part["image_url"] as? [String: Any] {
                                    url = imgObj["url"] as? String
                                } else if let imgStr = part["image_url"] as? String {
                                    url = imgStr
                                } else if let urlStr = part["url"] as? String {
                                    url = urlStr
                                }
                                if let u = url {
                                    parts.append(["type": "image_url", "image_url": ["url": u]])
                                }
                            } else if type == "input_file", let fileData = part["file_data"] as? String {
                                parts.append(["type": "image_url", "image_url": ["url": fileData]])
                            }
                        }
                        if parts.count == 1, (parts[0]["type"] as? String) == "text" {
                            messages.append(["role": normalizedRole, "content": parts[0]["text"] as? String ?? ""])
                        } else {
                            messages.append(["role": normalizedRole, "content": parts])
                        }
                    }
                } else if (item["type"] as? String) == "message", (item["role"] as? String) == "assistant" {
                    var text = ""
                    if let contentArr = item["content"] as? [[String: Any]] {
                        text = contentArr.filter { ($0["type"] as? String) == "output_text" }.compactMap { $0["text"] as? String }.joined()
                    }
                    messages.append(["role": "assistant", "content": text])
                } else if (item["type"] as? String) == "function_call" {
                    let callId = (item["call_id"] as? String) ?? "call_\(UUID().uuidString.prefix(9))"
                    let name = (item["name"] as? String) ?? ""
                    var argsStr = "{}"
                    if let argsString = item["arguments"] as? String {
                        argsStr = argsString
                    } else if let argsObj = item["arguments"] {
                        argsStr = String(data: (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data(), encoding: .utf8) ?? "{}"
                    }
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [[
                            "id": callId,
                            "type": "function",
                            "function": ["name": name, "arguments": argsStr]
                        ]]
                    ])
                } else if (item["type"] as? String) == "function_call_output" {
                    let callId = (item["call_id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? "unknown_function"
                    var outputStr = ""
                    if let s = item["output"] as? String {
                        outputStr = s
                    } else if let o = item["output"] {
                        outputStr = String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? ""
                    }
                    messages.append(["role": "tool", "tool_call_id": callId, "name": name, "content": outputStr])
                }
            }
        }

        if messages.isEmpty, let existingMessages = jsonReq["messages"] as? [[String: Any]] {
            messages = existingMessages
        }

        appendLog("[V1/RESP] Stream: \(isStreaming), Messages: \(messages.count), Model: \(modelToUse)")

        let respId = generateId(prefix: "resp_")
        let msgId = generateId(prefix: "msg_")

        func buildToolDeclarations(_ toolList: [[String: Any]]) -> [[String: Any]] {
            var decls: [[String: Any]] = []
            for t in toolList {
                let fn = (t["function"] as? [String: Any]) ?? t
                let name = (fn["name"] as? String) ?? ""
                let desc = (fn["description"] as? String) ?? ""
                let params = (fn["parameters"] as? [String: Any]) ?? ["type": "object", "properties": [:]]
                decls.append([
                    "name": name,
                    "description": desc,
                    "parameters": self.sanitizeToolSchema(params)
                ])
            }
            return decls
        }

        if isStreaming {
            let sseHeaders = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            connection.send(content: sseHeaders.data(using: .utf8), completion: .contentProcessed { _ in })

            func sendEvent(_ event: String, _ data: [String: Any], then: (() -> Void)? = nil) {
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else { then?(); return }
                let payload = "event: \(event)\ndata: \(jsonStr)\n\n"
                connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
                    then?()
                })
            }

            sendEvent("response.created", [
                "type": "response.created",
                "response": [
                    "id": respId,
                    "created_at": Int(Date().timeIntervalSince1970),
                    "model": requestedModel ?? modelToUse
                ]
            ])

            Task {
                do {
                    let (contents, systemText, hasInlinedImages, imageLoadError) = await self.buildGeminiContents(from: messages)
                    if let err = imageLoadError {
                        sendEvent("error", ["type": "error", "code": "image_error", "message": err, "sequence_number": 0], then: { self.finishConnection(connection) })
                        return
                    }
                    if contents.isEmpty {
                        sendEvent("error", ["type": "error", "code": "empty_prompt", "message": "No messages provided", "sequence_number": 0], then: { self.finishConnection(connection) })
                        return
                    }

                    var genConfig: [String: Any] = [
                        "temperature": temperature,
                        "maxOutputTokens": maxOutputTokens
                    ]
                    if !hasInlinedImages && supportsThinkingLevel(modelToUse) {
                        genConfig["thinkingConfig"] = ["thinkingLevel": "high"]
                    }

                    var reqBody: [String: Any] = ["contents": contents, "generationConfig": genConfig]
                    if !systemText.isEmpty {
                        reqBody["systemInstruction"] = ["role": "system", "parts": [["text": systemText]]]
                    }
                    if let toolList = tools, !toolList.isEmpty {
                        reqBody["tools"] = [["function_declarations": buildToolDeclarations(toolList)]]
                    }

                    guard let url = self.vertexEndpointURL(model: modelToUse, verb: "streamGenerateContent?alt=sse") else {
                        sendEvent("error", ["type": "error", "code": "invalid_url", "message": "Invalid Vertex endpoint", "sequence_number": 999], then: { self.finishConnection(connection) })
                        return
                    }

                    let (bytes, httpResp) = try await self.vertexStreamRequest(url: url, bodyDict: reqBody)
                    guard (200...299).contains(httpResp.statusCode) else {
                        sendEvent("error", ["type": "error", "code": "gemini_error", "message": "Gemini API Error (\(httpResp.statusCode))", "sequence_number": 999], then: { self.finishConnection(connection) })
                        return
                    }

                    var hasStartedText = false
                    var outputIndexCounter = 0

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let jsonStr = trimmed.hasPrefix("data: ") ? String(trimmed.dropFirst(6)) : String(trimmed.dropFirst(5))
                        if jsonStr.isEmpty || jsonStr == "[DONE]" { continue }

                        guard let d = jsonStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let candidates = obj["candidates"] as? [[String: Any]],
                              let firstCand = candidates.first,
                              let contentObj = firstCand["content"] as? [String: Any],
                              let parts = contentObj["parts"] as? [[String: Any]] else { continue }

                        for p in parts {
                            if (p["thought"] as? Bool) == true { continue }
                            let sig = (p["thought_signature"] as? String) ?? (p["thoughtSignature"] as? String)

                            if let text = p["text"] as? String {
                                if !hasStartedText {
                                    hasStartedText = true
                                    sendEvent("response.output_item.added", ["type": "response.output_item.added", "output_index": 0, "item": ["id": msgId, "type": "message"]])
                                    outputIndexCounter += 1
                                }
                                sendEvent("response.output_text.delta", ["type": "response.output_text.delta", "item_id": msgId, "delta": text])
                            }

                            if let fc = p["functionCall"] as? [String: Any], let fName = fc["name"] as? String {
                                let callId = self.generateId(prefix: "call_")
                                let args = fc["args"] as? [String: Any] ?? [:]
                                let argsStr = String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data(), encoding: .utf8) ?? "{}"
                                let currentIndex = outputIndexCounter
                                outputIndexCounter += 1

                                ToolCallLRUCache.shared.set(callId, name: fName, signature: sig)

                                sendEvent("response.output_item.added", ["type": "response.output_item.added", "output_index": currentIndex, "item": ["id": callId, "type": "function_call", "call_id": callId, "name": fName, "arguments": ""]])
                                sendEvent("response.function_call_arguments.delta", ["type": "response.function_call_arguments.delta", "item_id": callId, "output_index": currentIndex, "delta": argsStr])
                                sendEvent("response.output_item.done", ["type": "response.output_item.done", "output_index": currentIndex, "item": ["id": callId, "type": "function_call", "call_id": callId, "name": fName, "arguments": argsStr, "status": "completed"]])
                            }
                        }
                    }

                    if hasStartedText {
                        sendEvent("response.output_item.done", ["type": "response.output_item.done", "output_index": 0, "item": ["id": msgId, "type": "message"]])
                    }
                    self.appendLog("[V1/RESP] Stream completed. Model: \(modelToUse)")
                    sendEvent("response.completed", ["type": "response.completed", "response": ["usage": ["input_tokens": 0, "output_tokens": 0]]], then: { self.finishConnection(connection) })
                } catch {
                    self.appendLog("[V1/RESP ERROR] \(error.localizedDescription)")
                    sendEvent("error", ["type": "error", "code": "internal_error", "message": error.localizedDescription, "sequence_number": 999], then: { self.finishConnection(connection) })
                }
            }
        } else {
            Task {
                do {
                    let (contents, systemText, hasInlinedImages, imageLoadError) = await self.buildGeminiContents(from: messages)
                    if let err = imageLoadError {
                        self.sendError(connection, status: 400, message: err)
                        return
                    }

                    var genConfig: [String: Any] = [
                        "temperature": temperature,
                        "maxOutputTokens": maxOutputTokens
                    ]
                    if !hasInlinedImages && supportsThinkingLevel(modelToUse) {
                        genConfig["thinkingConfig"] = ["thinkingLevel": "high"]
                    }

                    var reqBody: [String: Any] = ["contents": contents, "generationConfig": genConfig]
                    if !systemText.isEmpty {
                        reqBody["systemInstruction"] = ["role": "system", "parts": [["text": systemText]]]
                    }
                    if let toolList = tools, !toolList.isEmpty {
                        reqBody["tools"] = [["function_declarations": buildToolDeclarations(toolList)]]
                    }

                    guard let url = self.vertexEndpointURL(model: modelToUse, verb: "generateContent") else {
                        self.sendError(connection, status: 400, message: "Invalid Vertex Endpoint URL")
                        return
                    }

                    let (data, httpResp) = try await self.vertexJSONRequest(url: url, bodyDict: reqBody)
                    guard (200...299).contains(httpResp.statusCode) else {
                        let errStr = String(data: data, encoding: .utf8) ?? ""
                        self.sendError(connection, status: httpResp.statusCode, message: "Gemini API Error: \(errStr)")
                        return
                    }

                    var replyText = ""
                    var outputItems: [[String: Any]] = []

                    if let geminiResp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = geminiResp["candidates"] as? [[String: Any]],
                       let firstCand = candidates.first,
                       let contentObj = firstCand["content"] as? [String: Any],
                       let parts = contentObj["parts"] as? [[String: Any]] {

                        for p in parts {
                            if let t = p["text"] as? String { replyText += t }
                            if let fc = p["functionCall"] as? [String: Any], let fName = fc["name"] as? String {
                                let callId = self.generateId(prefix: "call_")
                                let args = fc["args"] as? [String: Any] ?? [:]
                                let argsStr = String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data(), encoding: .utf8) ?? "{}"
                                let sig = (p["thought_signature"] as? String) ?? (p["thoughtSignature"] as? String)

                                ToolCallLRUCache.shared.set(callId, name: fName, signature: sig)

                                outputItems.append([
                                    "id": self.generateId(prefix: "fc_"),
                                    "type": "function_call",
                                    "call_id": callId,
                                    "name": fName,
                                    "arguments": argsStr,
                                    "status": "completed"
                                ])
                            }
                        }
                    }

                    if !replyText.isEmpty {
                        outputItems.insert([
                            "id": msgId,
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "content": [["type": "output_text", "text": replyText]]
                        ], at: 0)
                    }

                    let respPayload: [String: Any] = [
                        "id": respId,
                        "model": requestedModel ?? modelToUse,
                        "output": outputItems,
                        "usage": ["input_tokens": 0, "output_tokens": 0]
                    ]

                    let outData = try JSONSerialization.data(withJSONObject: respPayload)
                    self.sendJson(connection, status: 200, json: String(data: outData, encoding: .utf8) ?? "{}")
                    self.appendLog("[V1/RESP] Response returned successfully.")
                } catch {
                    self.sendError(connection, status: 500, message: error.localizedDescription)
                    self.appendLog("[V1/RESP ERROR] \(error.localizedDescription)")
                }
            }
        }
    }

    // A `.send` completion firing only means the data was handed to the network stack,
    // not that it was flushed over TCP — calling `cancel()` right after can drop the
    // last write on a connection that already had several prior sends queued. Marking
    // the final send as `.finalMessage`/`isComplete` makes Network.framework flush
    // everything before it closes, so nothing gets dropped.
    private func finishConnection(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJson(_ connection: NWConnection, status: Int, json: String) {
        let bodyData = json.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: *\r
        \r\n
        """
        var full = headers.data(using: .utf8) ?? Data()
        full.append(bodyData)
        connection.send(content: full, completion: .contentProcessed { _ in connection.cancel() })
    }
    
    private func sendCORS(_ connection: NWConnection) {
        let headers = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    
    private func sendError(_ connection: NWConnection, status: Int, message: String) {
        let payload: [String: Any] = ["error": ["message": message, "type": status < 500 ? "invalid_request_error" : "api_error"]]
        let errJson = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\": {\"message\": \"error\"}}"
        sendJson(connection, status: status, json: errJson)
    }
    
    private func sendSimpleResponse(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = "HTTP/1.1 \(status) OK\r\nContent-Length: \(bodyData.count)\r\n\r\n"
        var full = headers.data(using: .utf8) ?? Data()
        full.append(bodyData)
        connection.send(content: full, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Main SwiftUI View (1:1 Windows Control Panel Design)

struct ContentView: View {
    @ObservedObject private var server = LocalProxyServer.shared
    @ObservedObject private var auth = GoogleADCAuthManager.shared
    @State private var isProjectIdVisible: Bool = false
    @State private var isLogExpanded: Bool = true
    @State private var isShowingFilePicker: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Fixed, non-scrolling top area (sections 1-6) — never resizes with the window.
            VStack(alignment: .leading, spacing: 18) {
                // 1. App Title Bar & API Quick Test
                HStack {
                    Text("Vertex OpenAI Proxy")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(Color.winLabelText)
                    
                    Spacer()
                    
                    Button(action: { server.runTestConnection() }) {
                        HStack(spacing: 5) {
                            if server.isTestingPrompt {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.orange)
                            }
                            Text("API 테스트")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.winLabelText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.winBorderColor, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!server.isRunning || server.isTestingPrompt)
                }
                
                // 2. Server Status Badge
                HStack(spacing: 8) {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(server.isRunning ? "Running" : "Stopped")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color.winLabelText)
                    
                    if !server.testResultPreview.isEmpty {
                        Text("(\(server.testResultPreview))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                // 3. Google ADC Authentication Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                                .foregroundColor(auth.isAdcAvailable ? .green : .orange)
                            Text("Google Cloud ADC 인증")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color.winLabelText)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(auth.isAdcAvailable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(auth.isAdcAvailable ? (auth.userEmail.isEmpty ? "인증됨" : auth.userEmail) : "인증 필요")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(auth.isAdcAvailable ? .green : .orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white)
                        .cornerRadius(6)
                    }
                    
                    HStack(spacing: 10) {
                        // Option 1: Copy Terminal Command
                        Button(action: {
                            auth.copyAuthCommand()
                            server.appendLog("[ADC] 클립보드에 'gcloud auth application-default login' 명령어가 복사되었습니다.")
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                Text("인증 터미널 명령어 복사")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        
                        // Option 2: Load JSON File directly with Tooltip Icon
                        HStack(spacing: 6) {
                            Button(action: {
                                isShowingFilePicker = true
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "folder")
                                    Text("인증 JSON 파일 로드")
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.winLabelText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.winBorderColor, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            
                            // Help tooltip
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .help(auth.defaultAdcPathHint)
                        }
                        
                        Spacer()
                        
                        if auth.isAdcAvailable {
                            Button("로그아웃") {
                                auth.logoutADC()
                                server.appendLog("[ADC] 로그아웃되었습니다.")
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.7))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.winBorderColor, lineWidth: 1))
                .alert("터미널 명령어 복사 완료", isPresented: $auth.showCopySuccessAlert) {
                    Button("확인", role: .cancel) { }
                } message: {
                    Text("클립보드에 인증 명령어가 복사되었습니다.\n\n터미널(Terminal) 앱을 열고 붙여넣기(⌘V) 후 Enter를 눌러 브라우저 로그인을 완료해 주세요.\n\n인증이 끝나면 옆의 [인증 JSON 파일 로드] 버튼을 눌러 생성된 파일을 로드해 주세요.")
                }
                .fileImporter(
                    isPresented: $isShowingFilePicker,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        if url.startAccessingSecurityScopedResource() {
                            defer { url.stopAccessingSecurityScopedResource() }
                            if let data = try? Data(contentsOf: url),
                               let str = String(data: data, encoding: .utf8) {
                                if auth.parseAndStoreAdcJson(jsonString: str) {
                                    server.appendLog("[ADC] 파일 로드 및 자격증명 영구 저장 완료! (\(url.lastPathComponent))")
                                }
                            }
                        }
                    }
                }
                
                // 4. Settings Form (High Contrast Dark Inputs)
                VStack(spacing: 14) {
                    HStack(alignment: .center) {
                        Text("Google Cloud Project ID")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.winLabelText)
                            .frame(width: 180, alignment: .leading)
                        
                        HStack {
                            if isProjectIdVisible {
                                TextField("ai-test-508806", text: $server.projectId)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(Color.winInputText)
                            } else {
                                SecureField("ai-test-508806", text: $server.projectId)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(Color.winInputText)
                            }
                            
                            Button(action: { isProjectIdVisible.toggle() }) {
                                Image(systemName: isProjectIdVisible ? "eye.slash" : "eye")
                                    .foregroundColor(Color.gray)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.winInputBg)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.winBorderColor, lineWidth: 1)
                        )
                    }
                    
                    HStack(alignment: .center) {
                        Text("Location")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.winLabelText)
                            .frame(width: 180, alignment: .leading)
                        
                        TextField("global", text: $server.location)
                            .textFieldStyle(.plain)
                            .foregroundColor(Color.winInputText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.winInputBg)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.winBorderColor, lineWidth: 1)
                            )
                    }
                    
                    HStack(alignment: .center) {
                        Text("Gemini Model")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.winLabelText)
                            .frame(width: 180, alignment: .leading)
                        
                        Picker("", selection: $server.modelId) {
                            ForEach(server.availableModels, id: \.self) { m in
                                Text(m)
                                    .foregroundColor(Color.winInputText)
                                    .tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.winInputBg)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.winBorderColor, lineWidth: 1)
                        )
                    }
                    
                    HStack(alignment: .center) {
                        Text("Port")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.winLabelText)
                            .frame(width: 180, alignment: .leading)
                        
                        TextField("3000", value: $server.port, format: .number)
                            .textFieldStyle(.plain)
                            .foregroundColor(Color.winInputText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.winInputBg)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.winBorderColor, lineWidth: 1)
                            )
                    }
                }
                
                // 5. Action Buttons Bar
                HStack(spacing: 12) {
                    Button("Start") {
                        server.startServer()
                    }
                    .buttonStyle(WinControlButtonStyle(backgroundColor: Color.winStartBtn))
                    
                    Button("Stop") {
                        server.stopServer()
                    }
                    .buttonStyle(WinControlButtonStyle(backgroundColor: Color.winStopBtn))
                    
                    Button("Restart") {
                        server.restartServer()
                    }
                    .buttonStyle(WinControlButtonStyle(backgroundColor: Color.winRestartBtn))
                    
                    Button("Save & Restart") {
                        server.saveAndRestart()
                    }
                    .buttonStyle(WinControlButtonStyle(backgroundColor: Color.winSaveBtn))
                }
                
                // 6. Tray Info Footnote
                Text("창을 닫아도 메뉴바 아이콘을 통해 백그라운드에서 계속 실행됩니다. 완전 종료는 메뉴바 메뉴에서 가능합니다.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray)
            }
            .padding(24)

            // 7. Collapsible Log Section (only this grows/shrinks with the window)
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    withAnimation { isLogExpanded.toggle() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isLogExpanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                            .font(.system(size: 10))
                        Text("Log")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(Color.winLabelText)
                }
                .buttonStyle(.plain)

                if isLogExpanded {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(server.logOutput)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .id("logBottom")
                        }
                        .frame(minHeight: 120, maxHeight: .infinity)
                        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                        .cornerRadius(12)
                        .onChange(of: server.logOutput) { _ in
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxHeight: isLogExpanded ? .infinity : nil)

            // 8. Copyright / License Footer
            HStack {
                Spacer()
                Text("© 2026 TJ. Choi. All rights reserved.  ·  tj.choi.79@gmail.com  ·  License: All Rights Reserved")
                    .font(.system(size: 10))
                    .foregroundColor(Color.gray)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .background(Color.winBackground.ignoresSafeArea())
    }
}

#Preview {
    ContentView()
}
