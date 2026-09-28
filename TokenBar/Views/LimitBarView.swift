import SwiftUI

/// La barra sola: fondo tenue y relleno proporcional a la utilización (0…1).
///
/// La comparten la fila plegada —que muestra solo la ventana más comprometida— y
/// `LimitBarView`, que la acompaña de nombre, porcentaje y cuenta regresiva.
struct LimitBarTrack: View {
    let utilization: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geometry.size.width * min(max(utilization, 0), 1)))
            }
        }
    }
}

/// Barra de una ventana de límite: nombre, porcentaje, barra de progreso y cuenta regresiva.
struct LimitBarView: View {
    let window: LimitWindow
    /// Se recalcula desde fuera para que la cuenta regresiva avance sin refrescar datos.
    let now: Date

    private var tint: Color {
        switch window.severity {
        case .normal:   .accentColor
        case .warning:  .orange
        case .critical: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(window.percent)%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(window.severity == .normal ? .primary : tint)
            }

            LimitBarTrack(utilization: window.utilization, tint: tint)
                .frame(height: 5)

            if let remaining = window.timeRemaining(from: now) {
                Text("resetea en \(remaining)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(window.name): \(window.percent) por ciento usado"]
        if let remaining = window.timeRemaining(from: now) {
            parts.append("resetea en \(remaining)")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Barras") {
    VStack(alignment: .leading, spacing: 10) {
        LimitBarView(window: LimitWindow(name: "5 horas", utilization: 0.21,
                                         resetsAt: Date().addingTimeInterval(4 * 3600 + 900)),
                     now: Date())
        LimitBarView(window: LimitWindow(name: "Semanal", utilization: 0.87,
                                         resetsAt: Date().addingTimeInterval(10 * 3600)),
                     now: Date())
    }
    .frame(width: 276)
    .padding()
}
