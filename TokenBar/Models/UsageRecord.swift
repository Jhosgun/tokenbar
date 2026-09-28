import Foundation

/// Un delta de consumo ya atribuido a un día local.
struct UsageRecord: Codable, Hashable, Sendable {
    var source: AppSource
    /// Día local en formato "yyyy-MM-dd".
    var day: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    /// Costo en USD ya calculado por el collector vía `Pricing`.
    var costUSD: Double

    /// Suma de los cuatro conteos de tokens.
    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    init(source: AppSource, day: String, inputTokens: Int = 0, outputTokens: Int = 0,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, costUSD: Double = 0) {
        self.source = source
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    /// Suma componente a componente. Precondición: mismo `source` y mismo `day`.
    /// El resultado conserva el `source` y el `day` de `lhs`.
    static func + (lhs: UsageRecord, rhs: UsageRecord) -> UsageRecord {
        assert(lhs.source == rhs.source && lhs.day == rhs.day,
               "UsageRecord.+ requiere mismo source y mismo day")
        return UsageRecord(
            source: lhs.source,
            day: lhs.day,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            costUSD: lhs.costUSD + rhs.costUSD
        )
    }
}

/// Helper de días ("yyyy-MM-dd", zona horaria local), usado por TODOS los módulos.
enum DayKey {
    /// Clave de día del `date` dado, en la zona horaria del `calendar`.
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let cal = gregorian(from: calendar)
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        return format(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// Clave de día de hoy.
    static func today(calendar: Calendar = .current) -> String {
        string(from: Date(), calendar: calendar)
    }

    /// Últimos `count` días terminando en el día de `date`, del más viejo al más nuevo.
    static func lastDays(_ count: Int, endingAt date: Date = Date(),
                         calendar: Calendar = .current) -> [String] {
        guard count > 0 else { return [] }
        let cal = gregorian(from: calendar)
        let end = cal.startOfDay(for: date)
        var days: [String] = []
        days.reserveCapacity(count)
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: end) else { continue }
            let parts = cal.dateComponents([.year, .month, .day], from: day)
            days.append(format(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0))
        }
        return days
    }

    /// Calendario gregoriano con la zona horaria del calendario recibido, para que la clave
    /// sea siempre "yyyy-MM-dd" proléptico gregoriano sin importar el calendario del sistema.
    private static func gregorian(from calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian { return calendar }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// Formateo ASCII fijo, independiente del locale (no usa DateFormatter).
    private static func format(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}
