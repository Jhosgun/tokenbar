import Foundation
import Testing

@testable import TokenBar

// MARK: - Helpers

/// Clave de día desplazada `offset` días hacia atrás desde hoy.
private func dayKey(daysAgo offset: Int) throws -> String {
    let calendar = Calendar.current
    let date = try #require(calendar.date(byAdding: .day, value: -offset, to: Date()))
    return DayKey.string(from: date, calendar: calendar)
}

@Suite("Streak")
struct StreakTests {

    @Test("sin días activos la racha es 0")
    func sinDatos() {
        let today = DayKey.today()
        #expect(Streak.current(activeDays: [], today: today) == 0)
    }

    @Test("un solo día activo, hoy, da racha 1")
    func unSoloDiaHoy() {
        let today = DayKey.today()
        #expect(Streak.current(activeDays: [today], today: today) == 1)
    }

    @Test("hoy en cero pero ayer con consumo no rompe la racha")
    func hoyEnCeroAyerPositivo() throws {
        let today = DayKey.today()
        let yesterday = try dayKey(daysAgo: 1)
        // Solo ayer activo; hoy todavía no tiene consumo (el día apenas empieza).
        #expect(Streak.current(activeDays: [yesterday], today: today) == 1)
    }

    @Test("hoy en cero y ayer también en cero: racha 0")
    func hoyYAyerEnCero() throws {
        let today = DayKey.today()
        let twoDaysAgo = try dayKey(daysAgo: 2)
        // Activo hace 2 días pero no ayer: la racha ya se rompió.
        #expect(Streak.current(activeDays: [twoDaysAgo], today: today) == 0)
    }

    @Test("varios días consecutivos terminando hoy se cuentan todos")
    func variosDiasConsecutivos() throws {
        let today = DayKey.today()
        let active = Set([0, 1, 2, 3].map { try! dayKey(daysAgo: $0) })
        #expect(Streak.current(activeDays: active, today: today) == 4)
    }

    @Test("un hueco corta la racha en ese punto")
    func huecoCortaLaRacha() throws {
        let today = DayKey.today()
        // Hoy y ayer activos, pero hace 2 días no: la racha es 2, no sigue contando lo de
        // más atrás aunque también haya consumo ahí.
        let active = Set([0, 1, 3, 4].map { try! dayKey(daysAgo: $0) })
        #expect(Streak.current(activeDays: active, today: today) == 2)
    }

    @Test("terminando ayer con hueco entre ayer y hoy-1 también corta ahí")
    func huecoAnclandoEnAyer() throws {
        let today = DayKey.today()
        // Hoy sin consumo (se ancla en ayer). Ayer y hace 2 días activos, hace 3 días no.
        let active = Set([1, 2].map { try! dayKey(daysAgo: $0) })
        #expect(Streak.current(activeDays: active, today: today) == 2)
    }

    @Test("consumo de hace más de un día sin nada más reciente es racha 0")
    func soloViejoSinReciente() throws {
        let today = DayKey.today()
        let old = try dayKey(daysAgo: 10)
        #expect(Streak.current(activeDays: [old], today: today) == 0)
    }

    // MARK: - longestRun (mejor racha histórica)

    @Test("longestRun sin días activos es 0")
    func longestRunSinDatos() {
        #expect(Streak.longestRun(activeDays: []) == 0)
    }

    @Test("longestRun con un solo día es 1")
    func longestRunUnSoloDia() throws {
        let day = try dayKey(daysAgo: 30)
        #expect(Streak.longestRun(activeDays: [day]) == 1)
    }

    @Test("longestRun encuentra una racha vieja aunque no haya actividad reciente")
    func longestRunRachaVieja() throws {
        // Racha de 5 días que terminó hace tiempo; nada ni hoy ni ayer.
        let active = Set((10...14).map { try! dayKey(daysAgo: $0) })
        #expect(Streak.longestRun(activeDays: active) == 5)
    }

    @Test("longestRun se queda con el tramo más largo cuando hay varios separados por huecos")
    func longestRunVariosTramos() throws {
        // Tramo de 2 días (hace 20 y 21) y tramo de 4 días (hace 5, 6, 7, 8): gana el de 4.
        let active = Set([20, 21, 5, 6, 7, 8].map { try! dayKey(daysAgo: $0) })
        #expect(Streak.longestRun(activeDays: active) == 4)
    }

    @Test("longestRun considera una racha que llega hasta hoy igual que cualquier otra")
    func longestRunHastaHoy() throws {
        let active = Set([0, 1, 2].map { try! dayKey(daysAgo: $0) })
        #expect(Streak.longestRun(activeDays: active) == 3)
    }

    @Test("una clave inválida sola no fabrica una racha de 1")
    func longestRunClaveInvalidaSola() {
        // "2026-02-31" no es una fecha real: sin filtrarla antes de contar, `longest`
        // arranca en 1 y esa cifra inventada sobreviviría (y se persistiría) como si fuera
        // una racha real.
        #expect(Streak.longestRun(activeDays: ["2026-02-31"]) == 0)
    }

    @Test("longestRun descarta las claves inválidas pero cuenta bien las válidas restantes")
    func longestRunDescartaSoloLasInvalidas() throws {
        let today = try dayKey(daysAgo: 0)
        let yesterday = try dayKey(daysAgo: 1)
        #expect(Streak.longestRun(activeDays: [today, yesterday, "2026-02-31", "no-es-un-día"]) == 2)
    }
}
