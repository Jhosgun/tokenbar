import Foundation

/// Cálculo de racha: días consecutivos con consumo, sobre las claves de día que ya usa
/// `DayKey`. Pura y sin estado: la fuente de verdad ("qué días tuvieron consumo") la trae
/// quien la llame, normalmente derivada de `usage.json`.
enum Streak {

    /// Días consecutivos con consumo, terminando hoy o ayer.
    ///
    /// Si `today` todavía no tiene consumo (el día apenas empieza), la racha no se rompe:
    /// se ancla en ayer y sigue contando hacia atrás desde ahí. Solo se rompe de verdad
    /// cuando pasa un día entero sin consumo. Un hueco en cualquier otro punto corta la
    /// cuenta ahí mismo.
    ///
    /// - Sin `activeDays`: 0.
    /// - Ni hoy ni ayer con consumo: 0.
    static func current(activeDays: Set<String>, today: String, calendar: Calendar = .current) -> Int {
        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = DayKey.adding(-1, to: cursor, calendar: calendar) else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while activeDays.contains(cursor) {
            count += 1
            guard let previous = DayKey.adding(-1, to: cursor, calendar: calendar) else { break }
            cursor = previous
        }
        return count
    }

    /// La racha más larga en todo `activeDays`, sin anclarse a hoy ni a ayer: el máximo de
    /// días consecutivos en cualquier tramo del historial retenido. Es lo que hay que usar
    /// para la mejor marca histórica — `current` por sí sola no sirve porque solo mira la
    /// racha vigente, y una racha vieja que ya terminó dejaría la mejor marca en 0.
    ///
    /// - Sin `activeDays`, o si ninguna clave es una fecha válida: 0.
    static func longestRun(activeDays: Set<String>, calendar: Calendar = .current) -> Int {
        // Una clave corrupta (por ejemplo de un `usage.json` dañado a mano) no debe fabricar
        // una racha: se descarta antes de arrancar el conteo, no después.
        let validDays = activeDays.filter { DayKey.date(from: $0, calendar: calendar) != nil }
        guard !validDays.isEmpty else { return 0 }
        // "yyyy-MM-dd" ordena igual lexicográfica que cronológicamente.
        let sortedDays = validDays.sorted()

        var longest = 1
        var current = 1
        for index in 1..<sortedDays.count {
            let previous = sortedDays[index - 1]
            let day = sortedDays[index]
            if DayKey.adding(1, to: previous, calendar: calendar) == day {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }
}
