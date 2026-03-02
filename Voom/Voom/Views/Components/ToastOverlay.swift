import SwiftUI

// MARK: - Toast Style

enum ToastStyle {
    case success
    case error
    case info

    var color: Color {
        switch self {
        case .success: VoomTheme.accentGreen
        case .error: VoomTheme.accentRed
        case .info: VoomTheme.textPrimary
        }
    }
}

// MARK: - Toast Item

struct ToastItem: Identifiable {
    let id = UUID()
    let message: String
    let icon: String
    let style: ToastStyle
}

// MARK: - Toast Manager

@Observable
@MainActor
final class ToastManager {
    static let shared = ToastManager()

    private(set) var current: ToastItem?
    private var queue: [ToastItem] = []
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, icon: String = "checkmark.circle.fill", style: ToastStyle = .info) {
        let item = ToastItem(message: message, icon: icon, style: style)
        if current != nil {
            queue.append(item)
        } else {
            present(item)
        }
    }

    func success(_ message: String, icon: String = "checkmark.circle.fill") {
        show(message, icon: icon, style: .success)
    }

    func error(_ message: String, icon: String = "xmark.circle.fill") {
        show(message, icon: icon, style: .error)
    }

    private func present(_ item: ToastItem) {
        current = item
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.smooth(duration: 0.25)) {
            current = nil
        }
        // Show next queued toast after a short delay
        if !queue.isEmpty {
            let next = queue.removeFirst()
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                present(next)
            }
        }
    }
}

// MARK: - Toast Overlay View

struct ToastOverlay: View {
    @State private var toast = ToastManager.shared

    var body: some View {
        VStack {
            if let item = toast.current {
                toastPill(item)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
            }
            Spacer()
        }
        .animation(.smooth(duration: 0.3), value: toast.current?.id)
    }

    private func toastPill(_ item: ToastItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.style.color)
            Text(item.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VoomTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule()
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
