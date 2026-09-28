//
//  verify.swift — harness de verificación headless de TokenBar
//
//  Corre el pipeline real (collectors -> UsageStore) sin abrir la GUI, contra los datos
//  reales del usuario en ~/.claude/projects (SOLO LECTURA), y escribe su estado en un
//  directorio temporal propio para no tocar ~/Library/Application Support/TokenBar.
//
//  Compilar y correr:
//
//    xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -o /tmp/tbverify \
//      Tools/verify.swift TokenBar/Models/*.swift TokenBar/Storage/*.swift \
//      TokenBar/Collectors/*.swift TokenBar/Support/Keychain.swift
//    /tmp/tbverify
//
//  Esta carpeta `Tools/` queda FUERA de los synchronized root groups del proyecto Xcode
//  (`TokenBar/` y `TokenBarTests/`), así que este archivo no entra al target de la app.
//
//  Inits que usa el harness (verificados contra Collectors/ y TokenBarApp.swift):
//    - ClaudeCodeCollector(rootDirectory: URL, store: CollectorStateStore)
//    - CursorCollector(store: CollectorStateStore)
//

import Foundation

@main
struct Verify {

    /// Objetivo de rendimiento del ciclo incremental (tasks.md: cada ciclo < 100 ms).
    private static let cycleBudgetMs: Double = 100

    static func main() async {
        let workDir = FileManager.default.temporaryDirectory.appending(path: "tokenbar-verify")
        // Partir de cero en cada corrida: sin cursores ni ids vistos de corridas anteriores.
        try? FileManager.default.removeItem(at: workDir)

        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")

        header("TokenBar — verificación headless")
        row("work dir", workDir.path)
        row("claude root", claudeRoot.path)
        row("existe", FileManager.default.fileExists(atPath: claudeRoot.path) ? "sí" : "NO")
        row("archivos .jsonl", "\(countJSONL(in: claudeRoot))")
        row("fecha (día local)", DayKey.today())

        let store = UsageStore(directory: workDir)
        let state = CollectorStateStore(directory: workDir)
        await store.load()
        await state.load()

        let claude = ClaudeCodeCollector(rootDirectory: claudeRoot, store: state)

        // --- Ciclo 1: bootstrap (lee el histórico según la política del collector) ---
        header("Ciclos")
        let (result1, ms1) = await measure { await claude.collect() }
        let applied1 = await store.apply(result1.records)
        await state.save()

        // --- Ciclo 2: incremental, sin cambios en disco. Debe ser casi instantáneo. ---
        let (result2, ms2) = await measure { await claude.collect() }
        let applied2 = await store.apply(result2.records)
        await state.save()

        print(pad("ciclo", 14) + pad("duración", 12) + pad("records", 10) + pad("tokens nuevos", 14) + "status")
        print(divider())
        print(pad("1 bootstrap", 14) + pad(fmt(ms1), 12) + pad("\(result1.records.count)", 10)
              + pad("\(applied1)", 14) + statusLabel(result1.status))
        print(pad("2 incremental", 14) + pad(fmt(ms2), 12) + pad("\(result2.records.count)", 10)
              + pad("\(applied2)", 14) + statusLabel(result2.status))

        if ms2 > cycleBudgetMs {
            print("")
            print("WARN: ciclo incremental tardó \(fmt(ms2)) (objetivo <\(Int(cycleBudgetMs))ms)")
        }

        // --- Snapshot de hoy ---
        let snapshot = await store.snapshot()
        let today = DayKey.today()

        header("Hoy (\(today))")
        print(pad("app", 16) + pad("input", 12) + pad("output", 12) + pad("cacheW", 12)
              + pad("cacheR", 12) + pad("total", 12) + "costo")
        print(divider())
        for source in AppSource.allCases {
            let r = snapshot.todayByApp[source] ?? UsageRecord(source: source, day: today)
            print(pad(source.displayName, 16)
                  + pad("\(r.inputTokens)", 12)
                  + pad("\(r.outputTokens)", 12)
                  + pad("\(r.cacheCreationTokens)", 12)
                  + pad("\(r.cacheReadTokens)", 12)
                  + pad("\(r.totalTokens)", 12)
                  + TokenFormatter.currency(r.costUSD))
        }
        print(divider())
        print(pad("TOTAL", 16) + pad("", 12) + pad("", 12) + pad("", 12) + pad("", 12)
              + pad("\(snapshot.todayTotalTokens)", 12) + TokenFormatter.currency(snapshot.todayCostUSD))
        print("")
        print("total formateado: \(TokenFormatter.short(snapshot.todayTotalTokens))"
              + "   costo: \(TokenFormatter.currency(snapshot.todayCostUSD))")

        // --- Serie de 7 días de Claude Code ---
        header("Claude Code — últimos 7 días")
        let series = snapshot.last7DaysByApp[.claudeCode] ?? []
        print(pad("día", 14) + pad("tokens", 14) + "corto")
        print(divider())
        for point in series {
            print(pad(point.day, 14) + pad("\(point.tokens)", 14) + TokenFormatter.short(point.tokens))
        }
        if series.count != 7 {
            print("WARN: la serie trae \(series.count) elementos, se esperaban 7")
        }

        // --- Status de collectors ---
        header("Status de collectors")
        print(pad("app", 16) + pad("records", 10) + "status")
        print(divider())
        print(pad(claude.source.displayName, 16) + pad("\(result2.records.count)", 10) + statusLabel(result2.status))

        let cursor = CursorCollector(store: state)
        let (cursorResult, cursorMs) = await measure { await cursor.collect() }
        print(pad(cursor.source.displayName, 16) + pad("\(cursorResult.records.count)", 10)
              + statusLabel(cursorResult.status) + "  (\(fmt(cursorMs)))")

        // --- Persistencia ---
        header("Archivos escritos")
        for name in ["usage.json", "state.json"] {
            let url = workDir.appending(path: name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            row(name, size.map { "\($0) bytes" } ?? "NO EXISTE")
        }
        print("")
    }

    // MARK: - Medición

    /// Corre `work` y devuelve su resultado junto con la duración en milisegundos.
    /// `@MainActor` porque el entry point de `@main` lo está: así el closure no cruza aislamiento.
    @MainActor
    private static func measure<T>(_ work: () async -> T) async -> (T, Double) {
        let clock = ContinuousClock()
        var value: T?
        let elapsed = await clock.measure { value = await work() }
        return (value!, ms(elapsed))
    }

    private static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }

    private static func fmt(_ milliseconds: Double) -> String {
        String(format: "%.1fms", milliseconds)
    }

    // MARK: - Salida

    private static func statusLabel(_ status: CollectorStatus) -> String {
        status.uiMessage ?? "ok"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func divider() -> String {
        String(repeating: "-", count: 78)
    }

    private static func header(_ title: String) {
        print("")
        print("== \(title) " + String(repeating: "=", count: max(0, 75 - title.count)))
    }

    private static func row(_ label: String, _ value: String) {
        print(pad(label, 20) + value)
    }

    /// Cuenta archivos `.jsonl` bajo `root` (informativo; no sigue symlinks).
    private static func countJSONL(in root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            count += 1
        }
        return count
    }
}
