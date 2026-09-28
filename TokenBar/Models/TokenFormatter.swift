import Foundation

/// Formateo compacto de tokens y de costos para la UI.
enum TokenFormatter {
    /// Escala con su sufijo (1000 -> "K", 1e6 -> "M", ...).
    private struct Unit: Sendable {
        let scale: UInt
        let suffix: String
    }

    private static let units: [Unit] = [
        Unit(scale: 1_000, suffix: "K"),
        Unit(scale: 1_000_000, suffix: "M"),
        Unit(scale: 1_000_000_000, suffix: "B"),
        Unit(scale: 1_000_000_000_000, suffix: "T")
    ]

    /// 0 -> "0", 950 -> "950", 12000 -> "12.0K", 12400 -> "12.4K", 999_999 -> "1.0M",
    /// 1_200_000 -> "1.2M", 1_000_000_000 -> "1.0B". Negativos: prefijo "-".
    /// Menos de 1000 va sin sufijo; el resto siempre con 1 decimal (el ".0" NO se elimina)
    /// y redondeo half-up.
    static func short(_ value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = value.magnitude
        if magnitude < units[0].scale { return sign + String(magnitude) }

        var index = 0
        while index + 1 < units.count && magnitude >= units[index + 1].scale {
            index += 1
        }
        let scale = units[index].scale
        // Décimas redondeadas half-up: round(magnitude / (scale / 10)), en aritmética entera
        // para no depender de la precisión de Double.
        var tenths = (magnitude + scale / 20) / (scale / 10)
        var suffix = units[index].suffix
        // El redondeo puede desbordar la escala (999_999 -> 1000.0K); sube de unidad.
        if tenths >= 10_000 && index + 1 < units.count {
            tenths = 10
            suffix = units[index + 1].suffix
        }
        return "\(sign)\(tenths / 10).\(tenths % 10)\(suffix)"
    }

    /// "$1.23" con 2 decimales; mayor que 0 y menor que 0.01 -> "<$0.01"; 0 -> "$0.00".
    static func currency(_ value: Double) -> String {
        guard value > 0 else {
            return value < 0 ? String(format: "-$%.2f", -value) : "$0.00"
        }
        if value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }
}
