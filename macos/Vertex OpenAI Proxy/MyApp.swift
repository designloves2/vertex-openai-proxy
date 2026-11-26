import SwiftUI
import AppKit

// MARK: - App Delegate (Keep running when window is closed)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 창을 닫아도 메뉴바 백그라운드 실행 유지
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 창이 모두 닫히면 Dock에서 숨기고 메뉴바에만 표시
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                let stillOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !stillOpen {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

// MARK: - Main Application Scene

@main
struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    @ObservedObject private var server = LocalProxyServer.shared
    @ObservedObject private var auth = GoogleADCAuthManager.shared
    
    var body: some Scene {
        WindowGroup("Vertex OpenAI Proxy", id: "main") {
            ContentView()
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 820)
        #endif
        
        #if os(macOS)
        MenuBarExtra {
            MenuBarContentView(server: server, auth: auth)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: server.isRunning ? "bolt.fill" : "bolt.slash")
                Text(server.isRunning ? ":\(server.port)" : "Off")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        #endif
    }
}

// MARK: - Menu Bar Dropdown View

#if os(macOS)
struct MenuBarContentView: View {
    @ObservedObject var server: LocalProxyServer
    @ObservedObject var auth: GoogleADCAuthManager
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack {
            Text("Vertex OpenAI Proxy")
                .font(.headline)
            Text(server.isRunning ? "● 상태: 포트 \(server.port) 가동 중" : "○ 상태: 서버 중지됨")
                .foregroundColor(server.isRunning ? .green : .secondary)
            
            Divider()
            
            Button(action: {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }) {
                Label("컨트롤 패널 열기", systemImage: "macwindow")
            }
            .keyboardShortcut("o", modifiers: [.command])
            
            Divider()
            
            if server.isRunning {
                Button(action: { server.stopServer() }) {
                    Label("서버 중지 (Stop)", systemImage: "stop.circle")
                }
                Button(action: { server.restartServer() }) {
                    Label("서버 재시작 (Restart)", systemImage: "arrow.clockwise")
                }
            } else {
                Button(action: { server.startServer() }) {
                    Label("서버 시작 (Start)", systemImage: "play.circle")
                }
            }
            
            Divider()
            
            if auth.isAdcAvailable {
                Text("ADC: \(auth.userEmail.isEmpty ? "인증됨" : auth.userEmail)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button(action: {
                    auth.copyAuthCommand()
                }) {
                    Label("인증 터미널 명령어 복사", systemImage: "doc.on.doc")
                }
            }
            
            Divider()
            
            Button(role: .destructive, action: {
                server.stopServer()
                NSApplication.shared.terminate(nil)
            }) {
                Label("앱 완전 종료", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}
#endif
