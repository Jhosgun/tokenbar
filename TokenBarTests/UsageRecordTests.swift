import Foundation
import Testing

@testable import TokenBar

// MARK: - Helpers

/// Fecha construida en UTC, para que las pruebas no dependan de la zona del sistema.
private func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = hour
    parts.minute = minute
    return try #require(calendar.date(from: parts))
}

/// Calendario gregoriano anclado a una zona horaria concreta.
private func calendar(in timeZone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: timeZone))
    return calendar
}

private func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - UsageRecord

@Suite("UsageRecord")
struct UsageRecordTests {

    @Test("totalTokens suma los cuatro conteos")
    func totalTokens() {
        let record = UsageRecord(source: .claudeCode, day: "2026-08-03",
                                 inputTokens: 100, outputTokens: 25,
                                 cacheCreationTokens: 50, cacheReadTokens: 200)
        #expect(record.totalTokens == 375)
    }

    @Test("un registro recién creado tiene ceros por defecto")
    func valoresPorDefecto() {
        let record = UsageRecord(source: .cursor, day: "2026-08-03")
        #expect(record.inputTokens == 0)
        #expect(record.outputTokens == 0)
        #expect(record.cacheCreationTokens == 0)
        #expect(record.cacheReadTokens == 0)
        #expect(record.costUSD == 0)
        #expect(record.totalTokens == 0)
    }

    @Test("la suma es componente a componente y conserva source y día")
    func sumaComponenteAComponente() {
        let lhs = UsageRecord(source: .claudeCode, day: "2026-08-03",
                              inputTokens: 100, outputTokens: 25,
                              cacheCreationTokens: 50, cacheReadTokens: 200, costUSD: 0.25)
        let rhs = UsageRecord(source: .claudeCode, day: "2026-08-03",
                              inputTokens: 1, outputTokens: 2,
                              cacheCreationTokens: 3, cacheReadTokens: 4, costUSD: 0.75)
        let sum = lhs + rhs

        #expect(sum.source == .claudeCode)
        #expect(sum.day == "2026-08-03")
        #expect(sum.inputTokens == 101)
        #expect(sum.outputTokens == 27)
        #expect(sum.cacheCreationTokens == 53)
        #expect(sum.cacheReadTokens == 204)
        #expect(approxEqual(sum.costUSD, 1.0))
        #expect(sum.totalTokens == 385)
    }

    @Test("sumar un registro en cero no cambia nada")
    func sumaConCeroEsIdentidad() {
        let record = UsageRecord(source: .antigravity, day: "2026-08-03",
                                 inputTokens: 7, outputTokens: 8,
                                 cacheCreationTokens: 9, cacheReadTokens: 10, costUSD: 0.5)
        let zero = UsageRecord(source: .antigravity, day: "2026-08-03")
        #expect(record + zero == record)
    }

    @Test("sobrevive un round-trip de JSON")
    func codableRoundTrip() throws {
        let record = UsageRecord(source: .claudeCode, day: "2026-08-03",
                                 inputTokens: 1, outputTokens: 2,
                                 cacheCreationTokens: 3, cacheReadTokens: 4, costUSD: 0.01)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(UsageRecord.self, from: data)
        #expect(decoded == record)
    }
}

// MARK: - DayKey

@Suite("DayKey")
struct DayKeyTests {

    @Test("string(from:) usa la zona horaria del calendario recibido")
    func stringUsaZonaHoraria() throws {
        let instant = try utcDate(2026, 8, 3, 14, 5)
        let utc = try calendar(in: "UTC")
        let bogota = try calendar(in: "America/Bogota")
        let tokyo = try calendar(in: "Asia/Tokyo")

        #expect(DayKey.string(from: instant, calendar: utc) == "2026-08-03")
        #expect(DayKey.string(from: instant, calendar: bogota) == "2026-08-03")
        #expect(DayKey.string(from: instant, calendar: tokyo) == "2026-08-03")
    }

    @Test("un instante cerca de medianoche cae en días distintos según la zona")
    func stringCruzaMedianoche() throws {
        // 02:00 UTC sigue siendo el día 2 en Bogotá (UTC-5) y ya es el día 3 en Tokio (UTC+9).
        let instant = try utcDate(2026, 8, 3, 2, 0)
        let utc = try calendar(in: "UTC")
        let bogota = try calendar(in: "America/Bogota")
        let tokyo = try calendar(in: "Asia/Tokyo")

        #expect(DayKey.string(from: instant, calendar: utc) == "2026-08-03")
        #expect(DayKey.string(from: instant, calendar: bogota) == "2026-08-02")
        #expect(DayKey.string(from: instant, calendar: tokyo) == "2026-08-03")
    }

    @Test("el formato lleva ceros a la izquierda")
    func stringConCerosALaIzquierda() throws {
        let instant = try utcDate(2026, 1, 5, 12, 0)
        let utc = try calendar(in: "UTC")
        #expect(DayKey.string(from: instant, calendar: utc) == "2026-01-05")
    }

    @Test("today() coincide con string(from:) sobre la fecha actual")
    func todayEsConsistente() {
        #expect(DayKey.today() == DayKey.string(from: Date()))
    }

    @Test("lastDays(7) devuelve 7 días ordenados de viejo a nuevo terminando hoy")
    func lastDaysDesdeHoy() {
        let days = DayKey.lastDays(7)
        #expect(days.count == 7)
        #expect(days.last == DayKey.today())
        #expect(days == days.sorted())
        #expect(Set(days).count == 7)
    }

    @Test("lastDays no deja huecos y cruza el fin de mes")
    func lastDaysCruzaFinDeMes() throws {
        let end = try utcDate(2026, 3, 3, 12, 0)
        let utc = try calendar(in: "UTC")
        let days = DayKey.lastDays(7, endingAt: end, calendar: utc)
        #expect(days == ["2026-02-25", "2026-02-26", "2026-02-27", "2026-02-28",
                         "2026-03-01", "2026-03-02", "2026-03-03"])
    }

    @Test("lastDays incluye el 29 de febrero en un año bisiesto")
    func lastDaysAnioBisiesto() throws {
        let end = try utcDate(2024, 3, 1, 12, 0)
        let utc = try calendar(in: "UTC")
        let days = DayKey.lastDays(3, endingAt: end, calendar: utc)
        #expect(days == ["2024-02-28", "2024-02-29", "2024-03-01"])
    }

    @Test("lastDays con conteos degenerados")
    func lastDaysConteosDegenerados() throws {
        let end = try utcDate(2026, 8, 3, 12, 0)
        let utc = try calendar(in: "UTC")
        #expect(DayKey.lastDays(0, endingAt: end, calendar: utc).isEmpty)
        #expect(DayKey.lastDays(-1, endingAt: end, calendar: utc).isEmpty)
        #expect(DayKey.lastDays(1, endingAt: end, calendar: utc) == ["2026-08-03"])
    }

    @Test("date(from:) parsea la clave de vuelta al mismo día")
    func dateDesdeString() throws {
        let utc = try calendar(in: "UTC")
        let date = try #require(DayKey.date(from: "2026-08-03", calendar: utc))
        #expect(DayKey.string(from: date, calendar: utc) == "2026-08-03")
    }

    @Test("date(from:) devuelve nil con un formato inválido")
    func dateDesdeStringInvalido() {
        #expect(DayKey.date(from: "no-es-una-fecha") == nil)
        #expect(DayKey.date(from: "2026-08") == nil)
        // Un separador doblado deja un campo vacío: antes se descartaba silenciosamente y
        // corría el resto de columnas, devolviendo una fecha inventada.
        #expect(DayKey.date(from: "2026--08-03") == nil)
        // El 31 de febrero no existe: `Calendar` lo normaliza al día siguiente válido en vez
        // de fallar, así que hay que rechazarlo aparte comprobando el viaje de ida y vuelta.
        #expect(DayKey.date(from: "2026-02-31") == nil)
        // "+1" tiene el mismo ancho que "01" y `Int(_:)` lo acepta con signo: sin exigir
        // dígitos ASCII puros esto colaba como si fuera enero.
        #expect(DayKey.date(from: "2026-+1-01") == nil)
        #expect(DayKey.date(from: "2026-08-+3") == nil)
    }

    @Test("adding suma y resta días cruzando meses y años")
    func addingCruzaFronteras() throws {
        let utc = try calendar(in: "UTC")
        #expect(DayKey.adding(1, to: "2026-08-03", calendar: utc) == "2026-08-04")
        #expect(DayKey.adding(-1, to: "2026-08-01", calendar: utc) == "2026-07-31")
        #expect(DayKey.adding(-1, to: "2026-01-01", calendar: utc) == "2025-12-31")
        #expect(DayKey.adding(0, to: "2026-08-03", calendar: utc) == "2026-08-03")
    }

    @Test("adding devuelve nil con un formato inválido")
    func addingConFormatoInvalido() {
        #expect(DayKey.adding(1, to: "no-es-una-fecha") == nil)
        #expect(DayKey.adding(1, to: "2026--08-03") == nil)
        #expect(DayKey.adding(1, to: "2026-02-31") == nil)
        #expect(DayKey.adding(1, to: "2026-+1-01") == nil)
    }
}

// MARK: - Pricing

@Suite("Pricing")
struct PricingTests {

    @Test("un millón de tokens de input cuesta la tarifa de la familia")
    func costoPorMillonDeInput() {
        let fable = Pricing.cost(model: "claude-fable-5", inputTokens: 1_000_000,
                                 outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        let sonnet = Pricing.cost(model: "claude-sonnet-4-5", inputTokens: 1_000_000,
                                  outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        let opus = Pricing.cost(model: "claude-opus-4-8", inputTokens: 1_000_000,
                                outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        let haiku = Pricing.cost(model: "claude-haiku-4-5", inputTokens: 1_000_000,
                                 outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        #expect(approxEqual(fable, 10.00))
        #expect(approxEqual(sonnet, 3.00))
        #expect(approxEqual(opus, 5.00))
        #expect(approxEqual(haiku, 1.00))
    }

    @Test("cada componente usa su propia tarifa")
    func costoPorComponente() {
        let opusOutput = Pricing.cost(model: "claude-opus-4-8", inputTokens: 0,
                                      outputTokens: 1_000_000, cacheCreationTokens: 0,
                                      cacheReadTokens: 0)
        let opusCacheWrite = Pricing.cost(model: "claude-opus-4-8", inputTokens: 0,
                                          outputTokens: 0, cacheCreationTokens: 1_000_000,
                                          cacheReadTokens: 0)
        let opusCacheRead = Pricing.cost(model: "claude-opus-4-8", inputTokens: 0,
                                         outputTokens: 0, cacheCreationTokens: 0,
                                         cacheReadTokens: 1_000_000)
        let fableOutput = Pricing.cost(model: "claude-fable-5", inputTokens: 0,
                                       outputTokens: 1_000_000, cacheCreationTokens: 0,
                                       cacheReadTokens: 0)
        let fableCacheWrite = Pricing.cost(model: "claude-fable-5", inputTokens: 0,
                                           outputTokens: 0, cacheCreationTokens: 1_000_000,
                                           cacheReadTokens: 0)
        let fableCacheRead = Pricing.cost(model: "claude-fable-5", inputTokens: 0,
                                          outputTokens: 0, cacheCreationTokens: 0,
                                          cacheReadTokens: 1_000_000)
        let sonnetCacheRead = Pricing.cost(model: "claude-sonnet-4-5", inputTokens: 0,
                                           outputTokens: 0, cacheCreationTokens: 0,
                                           cacheReadTokens: 1_000_000)
        let haikuCacheWrite = Pricing.cost(model: "claude-haiku-4-5", inputTokens: 0,
                                           outputTokens: 0, cacheCreationTokens: 1_000_000,
                                           cacheReadTokens: 0)
        #expect(approxEqual(opusOutput, 25.00))
        #expect(approxEqual(opusCacheWrite, 6.25))
        #expect(approxEqual(opusCacheRead, 0.50))
        #expect(approxEqual(fableOutput, 50.00))
        #expect(approxEqual(fableCacheWrite, 12.50))
        #expect(approxEqual(fableCacheRead, 1.00))
        #expect(approxEqual(sonnetCacheRead, 0.30))
        #expect(approxEqual(haikuCacheWrite, 1.25))
    }

    @Test("cacheWrite es 1.25x el input y cacheRead es 0.1x en toda la tabla")
    func relacionEntreTarifas() throws {
        for model in ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-5", "claude-haiku-4-5"] {
            let rate = try #require(Pricing.pricing(forModel: model))
            #expect(approxEqual(rate.cacheWritePerMTok, rate.inputPerMTok * 1.25))
            #expect(approxEqual(rate.cacheReadPerMTok, rate.inputPerMTok * 0.1))
        }
    }

    @Test("el costo total suma los cuatro componentes")
    func costoCombinado() {
        // 100 input + 25 output + 50 cache write + 200 cache read, tarifas de opus.
        // Desglosado en sub-expresiones: como un solo literal el type-checker de Swift
        // no resuelve la sobrecarga en tiempo razonable.
        let input: Double = 100 * 5.00
        let output: Double = 25 * 25.00
        let cacheWrite: Double = 50 * 6.25
        let cacheRead: Double = 200 * 0.50
        let expected: Double = (input + output + cacheWrite + cacheRead) / 1_000_000
        let actual = Pricing.cost(model: "claude-opus-4-8", inputTokens: 100, outputTokens: 25,
                                  cacheCreationTokens: 50, cacheReadTokens: 200)
        #expect(approxEqual(actual, expected))
        #expect(approxEqual(actual, 0.0015375))
    }

    @Test("el match del modelo es case-insensitive y por substring")
    func matchPorSubstringSinDistinguirMayusculas() throws {
        let lower = try #require(Pricing.pricing(forModel: "claude-opus-4-8"))
        let upper = try #require(Pricing.pricing(forModel: "CLAUDE-OPUS-4-8"))
        let opus5 = try #require(Pricing.pricing(forModel: "claude-opus-5"))
        let fable5 = try #require(Pricing.pricing(forModel: "claude-fable-5"))
        let fableUpper = try #require(Pricing.pricing(forModel: "CLAUDE-FABLE-5"))
        let mixed = try #require(Pricing.pricing(forModel: "Claude-Sonnet-4-5"))
        let prefixed = try #require(Pricing.pricing(forModel: "anthropic/CLAUDE-HAIKU-4-5"))
        let bedrock = try #require(Pricing.pricing(forModel: "us.anthropic.claude-opus-4-8-v1:0"))

        #expect(lower.inputPerMTok == 5.00)
        #expect(upper.inputPerMTok == 5.00)
        #expect(upper.outputPerMTok == 25.00)
        #expect(opus5.inputPerMTok == 5.00)
        #expect(fable5.inputPerMTok == 10.00)
        #expect(fable5.outputPerMTok == 50.00)
        #expect(fableUpper.inputPerMTok == 10.00)
        #expect(mixed.inputPerMTok == 3.00)
        #expect(prefixed.inputPerMTok == 1.00)
        #expect(bedrock.inputPerMTok == 5.00)
    }

    @Test("mythos es un alias de la tarifa fable")
    func mythosEsAliasDeFable() throws {
        let mythos = try #require(Pricing.pricing(forModel: "claude-mythos-1"))
        let mythosUpper = try #require(Pricing.pricing(forModel: "CLAUDE-MYTHOS-1"))
        #expect(mythos.inputPerMTok == 10.00)
        #expect(mythos.outputPerMTok == 50.00)
        #expect(mythos.cacheWritePerMTok == 12.50)
        #expect(mythos.cacheReadPerMTok == 1.00)
        #expect(mythosUpper.inputPerMTok == 10.00)
    }

    @Test("el orden de match es haiku, luego fable/mythos, luego sonnet, luego opus")
    func ordenDeMatch() throws {
        // haiku gana sobre cualquier otro match.
        let conHaiku = try #require(Pricing.pricing(forModel: "haiku-fable-sonnet-opus"))
        let haikuYMythos = try #require(Pricing.pricing(forModel: "MYTHOS-HAIKU"))
        // fable/mythos ganan sobre sonnet y opus.
        let fablePrimero = try #require(Pricing.pricing(forModel: "fable-sonnet-opus"))
        let mythosPrimero = try #require(Pricing.pricing(forModel: "mythos-opus"))
        // sonnet gana sobre opus.
        let sonnetPrimero = try #require(Pricing.pricing(forModel: "sonnet-opus"))

        #expect(conHaiku.inputPerMTok == 1.00)
        #expect(haikuYMythos.inputPerMTok == 1.00)
        #expect(fablePrimero.inputPerMTok == 10.00)
        #expect(mythosPrimero.inputPerMTok == 10.00)
        #expect(sonnetPrimero.inputPerMTok == 3.00)
    }

    @Test("un modelo desconocido no tiene tarifa y cuesta 0")
    func modeloDesconocido() {
        // `<synthetic>` aparece de verdad en los transcripts de Claude Code.
        #expect(Pricing.pricing(forModel: "<synthetic>") == nil)
        #expect(Pricing.pricing(forModel: "gpt-5") == nil)
        #expect(Pricing.pricing(forModel: "") == nil)
        #expect(Pricing.cost(model: "<synthetic>", inputTokens: 1_000_000, outputTokens: 1_000_000,
                             cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000) == 0)
        #expect(Pricing.cost(model: "gpt-5", inputTokens: 1_000_000, outputTokens: 1_000_000,
                             cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000) == 0)
        #expect(Pricing.cost(model: "", inputTokens: 1_000_000, outputTokens: 0,
                             cacheCreationTokens: 0, cacheReadTokens: 0) == 0)
    }

    @Test("sin tokens el costo es 0")
    func sinTokensCuestaCero() {
        #expect(Pricing.cost(model: "claude-opus-4-8", inputTokens: 0, outputTokens: 0,
                             cacheCreationTokens: 0, cacheReadTokens: 0) == 0)
    }
}

@Suite("AppSource")
struct AppSourceTests {

    @Test("las herramientas con app de escritorio exponen su bundle id; las de solo CLI, no")
    func bundleIdentifiers() {
        #expect(AppSource.claudeCode.bundleIdentifier == "com.anthropic.claudefordesktop")
        #expect(AppSource.cursor.bundleIdentifier == "com.todesktop.230313mzl4w4u92")
        #expect(AppSource.codex.bundleIdentifier == "com.openai.codex")
        // Antigravity aquí es su CLI (`agy`), y Command Code y OpenCode no tienen app.
        #expect(AppSource.antigravity.bundleIdentifier == nil)
        #expect(AppSource.commandCode.bundleIdentifier == nil)
        #expect(AppSource.opencode.bundleIdentifier == nil)
    }

    @Test("solo Claude Code y Cursor tienen fuente de tokens; el resto es solo cuota")
    func fuentesDeTokens() {
        #expect(AppSource.claudeCode.hasTokenSource)
        #expect(AppSource.cursor.hasTokenSource)
        for source in [AppSource.antigravity, .codex, .commandCode, .opencode] {
            #expect(!source.hasTokenSource, "\(source.displayName) no tiene tokens que contar")
        }
    }

    @Test("toda fuente sin logo real tiene un SF Symbol de respaldo y un nombre visible")
    func fallbacks() {
        for source in AppSource.limitsCases {
            #expect(!source.displayName.isEmpty)
            #expect(!source.symbolName.isEmpty)
        }
    }

    @Test("la lista del popover trae las seis herramientas, sin repetir")
    func limitsCases() {
        #expect(AppSource.limitsCases.count == 6)
        #expect(Set(AppSource.limitsCases).count == 6)
    }
}

@Suite("SourceRowView")
struct SourceRowViewTests {

    @Test("el resumen usa la ventana más comprometida")
    func resumen() {
        let snapshot = LimitsSnapshot(
            source: .claudeCode,
            windows: [LimitWindow(name: "5 horas", utilization: 0.10, resetsAt: nil),
                      LimitWindow(name: "Semanal", utilization: 0.71, resetsAt: nil),
                      LimitWindow(name: "Mes", utilization: 0.30, resetsAt: nil)],
            planLabel: nil, status: .ok)
        #expect(snapshot.worst?.name == "Semanal")
        #expect(snapshot.worst?.percent == 71)
    }


    @Test("la ventana principal es la primera, no la más gastada")
    func ventanaPrincipal() {
        // Caso real de Claude Code: Fable al 100% no debe tapar la de 5 h.
        let snapshot = LimitsSnapshot(
            source: .claudeCode,
            windows: [LimitWindow(name: "5 horas", utilization: 0.09, resetsAt: nil),
                      LimitWindow(name: "Semanal", utilization: 0.72, resetsAt: nil),
                      LimitWindow(name: "Fable semanal", utilization: 1.0, resetsAt: nil)],
            planLabel: nil, status: .ok)
        #expect(snapshot.primary?.name == "5 horas")
        #expect(snapshot.worst?.name == "Fable semanal")
        // Y como la crítica no es la principal, la fila plegada la señala con un punto.
        #expect(snapshot.hiddenAlert?.name == "Fable semanal")
    }

    @Test("sin ventanas críticas escondidas no hay punto de aviso")
    func sinAviso() {
        let tranquila = LimitsSnapshot(
            source: .codex,
            windows: [LimitWindow(name: "5 horas", utilization: 0.10, resetsAt: nil),
                      LimitWindow(name: "Semanal", utilization: 0.40, resetsAt: nil)],
            planLabel: nil, status: .ok)
        #expect(tranquila.hiddenAlert == nil)

        // La principal crítica tampoco genera punto: ya se ve en rojo en la fila.
        let apretada = LimitsSnapshot(
            source: .codex,
            windows: [LimitWindow(name: "5 horas", utilization: 0.99, resetsAt: nil),
                      LimitWindow(name: "Semanal", utilization: 0.40, resetsAt: nil)],
            planLabel: nil, status: .ok)
        #expect(apretada.hiddenAlert == nil)
    }

    @Test("la antigüedad del último dato bueno se redacta en corto")
    func antiguedad() {
        let now = Date()
        #expect(SourceRowView.ago(now, now: now) == "ahora")
        #expect(SourceRowView.ago(now.addingTimeInterval(-12 * 60), now: now) == "hace 12m")
        #expect(SourceRowView.ago(now.addingTimeInterval(-125 * 60), now: now) == "hace 2h 5m")
        #expect(SourceRowView.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "hace 3d")
    }
}
