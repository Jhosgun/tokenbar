import SwiftUI

/// Una herramienta en el popover: logo, nombre y un resumen de una línea que se despliega
/// al hacer clic.
///
/// Plegada muestra solo la ventana más comprometida —la que decide si puedes seguir
/// trabajando—; desplegada muestra todas sus ventanas (5 h, semanal, mes…) y, si la
/// herramienta tiene fuente de tokens, el consumo de hoy con su sparkline.
struct SourceRowView: View {
    let source: AppSource
    /// Límites de la cuenta. `nil` mientras no se haya consultado todavía.
    let snapshot: LimitsSnapshot?
    /// Consumo de hoy. `nil` para las herramientas que no tienen fuente de tokens.
    let record: UsageRecord?
    let series: [DayTotal]
    /// Estado del collector de tokens, aparte del de los límites: una fuente puede tener
    /// la cuota al día y el contador roto, y eso hay que decirlo en vez de dejar un total
    /// viejo en pantalla sin aviso.
    let tokensStatus: CollectorStatus?
    let showCost: Bool
    /// Cuándo llegó el último dato bueno, para marcar la antigüedad cuando falla.
    let lastGoodAt: Date?
    /// Se recalcula desde fuera para que las cuentas regresivas avancen sin pedir datos.
    let now: Date
    @Binding var isExpanded: Bool

    private var windows: [LimitWindow] { snapshot?.windows ?? [] }

    /// La línea de tokens se muestra cuando la herramienta tiene fuente de tokens y hay un
    /// registro de hoy, aunque sea de cero: un día sin consumo es un dato, no una fuente
    /// ausente.
    private var tokensRecord: UsageRecord? {
        guard source.hasTokenSource else { return nil }
        return record ?? UsageRecord(source: source, day: DayKey.today())
    }

    /// Mensaje del contador de tokens cuando no está bien ("No configurado", "Token
    /// inválido"…). `nil` si va bien o si la herramienta no cuenta tokens.
    private var tokensMessage: String? {
        guard source.hasTokenSource, let tokensStatus, tokensStatus != .ok else { return nil }
        return tokensStatus.uiMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                summary
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)

            if isExpanded, canExpand {
                detail
                    .padding(.leading, 24)
                    .padding(.bottom, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Se puede desplegar si el detalle tiene algo que la línea de resumen no muestra: el
    /// nombre de la ventana y su cuenta regresiva, el plan, los tokens o un aviso de estado.
    private var canExpand: Bool {
        !windows.isEmpty || tokensRecord != nil || snapshot?.planLabel != nil
            || tokensMessage != nil
    }

    // MARK: - Resumen (plegado)

    private var summary: some View {
        HStack(spacing: 8) {
            SourceIconView(source: source)

            Text(source.displayName)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let primary = snapshot?.primary {
                // Un punto avisa de una ventana crítica que no es la principal (por
                // ejemplo un tope por modelo al 100% con las 5 h todavía holgadas).
                if let alert = snapshot?.hiddenAlert {
                    Circle()
                        .fill(tint(alert.severity))
                        .frame(width: 5, height: 5)
                        .help("\(alert.name): \(alert.percent)%")
                }
                Text("\(primary.percent)%")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(primary.severity == .normal ? .primary : tint(primary.severity))
                LimitBarTrack(utilization: primary.utilization, tint: tint(primary.severity))
                    .frame(width: 56, height: 5)
            } else if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(canExpand ? 1 : 0)
                .frame(width: 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel)
        .accessibilityHint(canExpand ? (isExpanded ? "Doble clic para plegar"
                                                   : "Doble clic para ver todas las ventanas") : "")
    }

    // MARK: - Detalle (desplegado)

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = snapshot?.planLabel {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(windows) { window in
                LimitBarView(window: window, now: now)
            }

            if let tokensRecord {
                tokensLine(tokensRecord)
            }

            if let message = tokensMessage {
                Text("Tokens: \(message)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let message = statusMessage, snapshot?.primary != nil {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func tokensLine(_ record: UsageRecord) -> some View {
        HStack(spacing: 8) {
            Text("Tokens hoy")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            SparklineView(series: series, tint: source.accentColor)
                .frame(width: 60)

            VStack(alignment: .trailing, spacing: 1) {
                Text(TokenFormatter.short(record.totalTokens))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if showCost {
                    Text(TokenFormatter.currency(record.costUSD))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(TokenFormatter.short(record.totalTokens)) tokens hoy")
    }

    // MARK: - Texto de estado

    /// Un fallo con dato viejo se cuenta como antigüedad ("hace 12m"); el resto de estados
    /// usan su mensaje de siempre. `nil` cuando todo está bien.
    var statusMessage: String? {
        guard let snapshot else { return "Consultando…" }
        if case .failed = snapshot.status, let lastGoodAt {
            return Self.ago(lastGoodAt, now: now)
        }
        return snapshot.status.uiMessage
    }

    private func tint(_ severity: LimitWindow.Severity) -> Color {
        switch severity {
        case .normal:   .accentColor
        case .warning:  .orange
        case .critical: .red
        }
    }

    private var summaryAccessibilityLabel: String {
        var parts = [source.displayName]
        if let primary = snapshot?.primary {
            parts.append("\(primary.name): \(primary.percent) por ciento usado")
        }
        if let alert = snapshot?.hiddenAlert {
            parts.append("atención, \(alert.name) al \(alert.percent) por ciento")
        }
        if let message = statusMessage {
            parts.append(message)
        }
        return parts.joined(separator: ", ")
    }

    /// `nonisolated` a propósito: es una función pura y los tests la llaman desde un
    /// contexto síncrono. En SDKs donde `View` implica `@MainActor`, sin esto no compila.
    nonisolated static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        switch minutes {
        case 0:        return "ahora"
        case ..<60:    return "hace \(minutes)m"
        case ..<1_440:
            let hours = minutes / 60
            let rest = minutes % 60
            return rest > 0 ? "hace \(hours)h \(rest)m" : "hace \(hours)h"
        default:       return "hace \(minutes / 1_440)d"
        }
    }
}

#Preview("Filas") {
    @Previewable @State var expanded = true

    let days = DayKey.lastDays(7)
    let series = zip(days, [12_000, 48_000, 31_000, 96_000, 74_000, 15_000, 120_000])
        .map { DayTotal(day: $0, tokens: $1) }

    return VStack(alignment: .leading, spacing: 10) {
        SourceRowView(
            source: .claudeCode,
            snapshot: LimitsSnapshot(
                source: .claudeCode,
                windows: [
                    LimitWindow(name: "5 horas", utilization: 0.21,
                                resetsAt: Date().addingTimeInterval(4 * 3600)),
                    LimitWindow(name: "Semanal", utilization: 0.87,
                                resetsAt: Date().addingTimeInterval(30 * 3600))
                ],
                planLabel: "max 5x", status: .ok),
            record: UsageRecord(source: .claudeCode, day: DayKey.today(),
                                inputTokens: 8_400, outputTokens: 21_600,
                                cacheCreationTokens: 40_000, cacheReadTokens: 50_000,
                                costUSD: 1.234),
            series: series,
            tokensStatus: .ok,
            showCost: true,
            lastGoodAt: nil,
            now: Date(),
            isExpanded: $expanded
        )

        SourceRowView(
            source: .antigravity,
            snapshot: LimitsSnapshot(source: .antigravity, windows: [], planLabel: nil,
                                     status: .invalidCredentials),
            record: nil, series: [], tokensStatus: nil, showCost: false, lastGoodAt: nil,
            now: Date(),
            isExpanded: .constant(false)
        )
    }
    .frame(width: 276)
    .padding(12)
}
