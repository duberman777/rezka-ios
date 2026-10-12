import SwiftUI
import WebKit

struct RezkaVerificationView: View {
    let session: RezkaBrowserSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(session.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                BrowserView(webView: session.webView)
            }
            .navigationTitle("Website verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { session.continueRequest() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reload page") { session.webView.reload() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private struct BrowserView: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ uiView: WKWebView, context: Context) { }
    }
}
