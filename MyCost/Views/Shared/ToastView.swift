import SwiftUI

/// The little banner. Non-interactive except tap-to-dismiss; never blocks input.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
            Text(toast.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(background, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
        .accessibilityAddTraits(.isStaticText)
    }

    private var icon: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var background: Color {
        switch toast.style {
        case .success: .green
        case .error: .red
        case .info: .secondary
        }
    }
}

private struct ToastHost: ViewModifier {
    @ObservedObject var center: ToastCenter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.current {
                    ToastView(toast: toast)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { center.dismiss() }
                        .id(toast.id)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: center.current)
    }
}

extension View {
    /// Attach once, near the app root, to render `ToastCenter` messages.
    func toastHost(_ center: ToastCenter = .shared) -> some View {
        modifier(ToastHost(center: center))
    }
}
