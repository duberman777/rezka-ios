#if DEBUG
import UIKit

@MainActor
enum RezkaLayoutDiagnostics {
    static func capture() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) else { return }
        let report: [String: Any] = [
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "screenWidth": scene.screen.bounds.width,
            "screenHeight": scene.screen.bounds.height,
            "windowWidth": window.bounds.width,
            "windowHeight": window.bounds.height,
            "windowX": window.frame.minX,
            "windowY": window.frame.minY,
            "safeTop": window.safeAreaInsets.top,
            "safeBottom": window.safeAreaInsets.bottom
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            RezkaPlaybackDiagnostics.save(data, name: "layout.json")
        }
        if ProcessInfo.processInfo.arguments.contains("--rezka-capture-screen") {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let data = image.pngData() { RezkaPlaybackDiagnostics.save(data, name: "screen.png") }
        }
    }
}
#endif
