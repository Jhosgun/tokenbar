import AppKit
import SwiftUI

/// Logo de una herramienta.
///
/// Cuando su app de escritorio está instalada se usa **su propio ícono**, pedido al sistema
/// por bundle id: así el logo es el real y TokenBar no empaqueta imágenes de terceros. Las
/// herramientas que solo tienen CLI (Command Code, OpenCode, el `agy` de Antigravity) no
/// tienen app que consultar y caen en su SF Symbol de siempre.
struct SourceIconView: View {
    let source: AppSource
    var size: CGFloat = 16

    var body: some View {
        if let icon = SourceIcon.icon(for: source) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: source.symbolName)
                .font(.system(size: size * 0.8))
                .foregroundStyle(source.accentColor)
                .frame(width: size, height: size)
        }
    }
}

/// Busca el ícono de cada app una sola vez por arranque: `NSWorkspace` toca el disco y la
/// vista se redibuja en cada ciclo de refresco.
@MainActor
enum SourceIcon {
    private static var cache: [AppSource: NSImage] = [:]
    /// Las fuentes que ya se buscaron y no tienen app. Van en un set aparte para no repetir
    /// la búsqueda en cada redibujo: son la mayoría (las herramientas de solo CLI).
    private static var missing: Set<AppSource> = []

    static func icon(for source: AppSource) -> NSImage? {
        if let cached = cache[source] { return cached }
        if missing.contains(source) { return nil }
        guard let icon = load(source) else {
            missing.insert(source)
            return nil
        }
        cache[source] = icon
        return icon
    }

    private static func load(_ source: AppSource) -> NSImage? {
        guard let identifier = source.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Color de acento por app. Vive en la capa de vistas (no en `AppSource`) porque es
/// puramente de UI. Se usan colores del sistema para que el contraste funcione en claro y
/// oscuro, y solo se ve cuando no hay logo real que mostrar.
extension AppSource {
    var accentColor: Color {
        switch self {
        case .claudeCode: .orange
        case .cursor: .blue
        case .antigravity: .purple
        case .codex: .green
        case .commandCode: .indigo
        case .opencode: .mint
        }
    }
}

#Preview("Logos") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(AppSource.limitsCases) { source in
            HStack(spacing: 8) {
                SourceIconView(source: source)
                Text(source.displayName)
                    .font(.callout)
            }
        }
    }
    .padding()
}
