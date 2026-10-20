import AppKit
import SwiftUI

/// Logo de una herramienta.
///
/// El orden de búsqueda es: primero el ícono de su app de escritorio, pedido al sistema por
/// bundle id; si no está instalada, el logo empaquetado en el catálogo de assets
/// (`LogoOpenCode`, `LogoAntigravity`, `LogoCommandCode`), que es cuadrado y se redondea al
/// dibujarlo; y como último recurso su SF Symbol.
struct SourceIconView: View {
    let source: AppSource
    var size: CGFloat = 16

    var body: some View {
        if let icon = SourceIcon.icon(for: source) {
            Image(nsImage: icon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(
                    cornerRadius: SourceIcon.cornerRadius(for: icon, size: size),
                    style: .continuous))
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
    /// Ícono resuelto y si es un logo empaquetado (cuadrado, sin el margen que ya traen los
    /// íconos de app del sistema), en cuyo caso hay que redondearlo al dibujarlo.
    struct Resolved {
        let image: NSImage
        let isBundled: Bool
    }

    /// Radio de la esquina de los logos empaquetados, proporcional al tamaño dibujado, para
    /// que se vean como los íconos de app que tienen al lado.
    private static let bundledCornerRatio: CGFloat = 0.22

    private static var cache: [AppSource: Resolved] = [:]
    /// Las fuentes que ya se buscaron y no tienen logo. Van en un set aparte para no repetir
    /// la búsqueda en cada redibujo: son la mayoría (las herramientas de solo CLI).
    private static var missing: Set<AppSource> = []

    static func icon(for source: AppSource) -> Resolved? {
        if let cached = cache[source] { return cached }
        if missing.contains(source) { return nil }
        guard let icon = load(source) else {
            missing.insert(source)
            return nil
        }
        cache[source] = icon
        return icon
    }

    /// Nombre del logo empaquetado en el catálogo para las herramientas que solo tienen CLI.
    private static func bundledLogoName(for source: AppSource) -> String? {
        switch source {
        case .antigravity: return "LogoAntigravity"
        case .commandCode: return "LogoCommandCode"
        case .opencode: return "LogoOpenCode"
        case .claudeCode, .cursor, .codex: return nil
        }
    }

    static func cornerRadius(for icon: Resolved, size: CGFloat) -> CGFloat {
        icon.isBundled ? size * bundledCornerRatio : 0
    }

    private static func load(_ source: AppSource) -> Resolved? {
        if let identifier = source.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return Resolved(image: NSWorkspace.shared.icon(forFile: url.path), isBundled: false)
        }
        guard let name = bundledLogoName(for: source),
              let image = NSImage(named: name) else { return nil }
        return Resolved(image: image, isBundled: true)
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
