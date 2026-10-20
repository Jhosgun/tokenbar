import AppKit
import SwiftUI

/// Rango de días que muestra la ventana de Estadísticas.
enum StatsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var label: String { "\(rawValue) días" }
}

/// Qué dibuja la gráfica: tokens acumulados (área apilada) o consumo de cada día (barras).
enum StatsChartKind: String, CaseIterable, Identifiable {
    case accumulated
    case daily

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accumulated: "Acumulado"
        case .daily: "Por día"
        }
    }
}

/// Colores de las series. Cada herramienta tiene el suyo fijo (`accentColor`); los modelos
/// toman uno de ocho tonos categóricos y lo conservan mientras la ventana siga abierta, así
/// que cambiar de rango no repinta a los que sobreviven. "Otros" va en un marrón neutro y los
/// "sin desglose" en grises, cada vez más claros: no deben competir con una serie con nombre ni
/// confundirse entre sí.
struct StatsColorAssigner {
    /// Los ocho tonos categóricos, en orden fijo (claro, oscuro): azul, naranja, aqua,
    /// amarillo, magenta, verde, violeta y rojo.
    private static let modelPalette: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
        (0xE87BA4, 0xD55181), (0x008300, 0x008300), (0x4A3AA7, 0x9085E9), (0xE34948, 0xE66767)
    ]

    /// Slot de cada modelo visto hasta ahora.
    private var slots: [String: Int] = [:]

    /// Color de cada serie de `data`, por nombre de serie. Asigna slots a los modelos nuevos
    /// sin tocar los que ya tenían uno.
    mutating func colors(for data: StatsData) -> [String: Color] {
        let models = data.series.compactMap { series -> String? in
            if case .model(let name) = series.kind { return name }
            return nil
        }
        // Un modelo nuevo toma el primer slot que no use ningún modelo de esta pantalla.
        var taken = Set(models.compactMap { slots[$0] })
        for name in models where slots[name] == nil {
            let slot = Self.modelPalette.indices.first { !taken.contains($0) } ?? slots.count % Self.modelPalette.count
            slots[name] = slot
            taken.insert(slot)
        }

        var result: [String: Color] = [:]
        for series in data.series {
            switch series.kind {
            case .tool(let source):
                result[series.name] = source.accentColor
            case .model(let name):
                let pair = Self.modelPalette[slots[name] ?? 0]
                result[series.name] = Self.dynamic(light: pair.light, dark: pair.dark)
            case .other:
                result[series.name] = Color(nsColor: .systemBrown)
            case .undisclosed(let source):
                result[series.name] = Self.undisclosedGray(for: source)
            }
        }
        return result
    }

    /// Un gris distinto por herramienta, para poder separar dos "sin desglose" apilados.
    private static func undisclosedGray(for source: AppSource) -> Color {
        let grays: [NSColor] = [.systemGray.withAlphaComponent(0.8), .systemGray.withAlphaComponent(0.6),
                                .systemGray.withAlphaComponent(0.45), .systemGray.withAlphaComponent(0.32),
                                .systemGray.withAlphaComponent(0.2)]
        let index = AppSource.tokenSources.firstIndex(of: source) ?? 0
        return Color(nsColor: grays[index % grays.count])
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
