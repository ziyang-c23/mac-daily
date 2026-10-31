import MacDailyCore
import AppKit
import Foundation

/// A separate, ordinary app provides a harmless REAL external AX target.
/// It starts only on request and quits when its window or the parent closes.
@MainActor
final class WindowPractice {
    private var application: NSRunningApplication?
    private var identifier: String?
    private var generation: UInt64 = 0
    private var returnObserver: NSObjectProtocol?

    func open(completion: @escaping (NSRunningApplication, String) -> Void, failure: @escaping (String) -> Void) {
        if let application, !application.isTerminated, let identifier {
            application.activate(options: [.activateAllWindows])
            completion(application, identifier); return
        }
        generation &+= 1
        let launchGeneration = generation
        let token = UUID().uuidString
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MacDailyPractice.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { failure(L10n.text("练习窗口组件缺失，请重新构建应用。")); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.arguments = ["--parent-pid", String(getpid()), "--practice-id", token, "--language", L10n.languageCode,
                            "-AppleLanguages", "(\(L10n.languageCode))"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { app?.terminate(); return }
                guard self.generation == launchGeneration else { app?.terminate(); return }
                guard let app else { failure(error?.localizedDescription ?? L10n.text("无法打开练习窗口")); return }
                self.application = app; self.identifier = token
                if let old = self.returnObserver { DistributedNotificationCenter.default().removeObserver(old) }
                self.returnObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.macdaily.practice.return"), object: token, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        AppDelegate.showSettings()
                        NotificationCenter.default.post(name: Notification.Name("MacDaily.showWindows"), object: nil)
                    }
                }
                completion(app, token)
            }
        }
    }
    func close() {
        generation &+= 1
        application?.terminate(); application = nil; identifier = nil
        if let returnObserver { DistributedNotificationCenter.default().removeObserver(returnObserver) }
        returnObserver = nil
    }
}
