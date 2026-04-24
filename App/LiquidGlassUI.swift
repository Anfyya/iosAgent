import SwiftUI

struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                NativeGlassPanel(content: content)
            } else {
                fallbackPanel
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: reduceTransparency)
    }

    private var fallbackPanel: some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(colorSchemeContrast == .increased ? .white.opacity(0.24) : .white.opacity(0.12), lineWidth: 1)
            }
    }
}

@available(iOS 26.0, *)
private struct NativeGlassPanel<Content: View>: View {
    let content: Content

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            content
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

struct GlassCapsuleBadge: View {
    let title: String
    let value: String

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
        }
    }
}
