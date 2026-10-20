import AppKit
import SwiftUI
import Testing

@testable import TokenBar

@Suite("Snapshots del resumen semanal")
@MainActor
struct WeekSummarySnapshotTests {

    static let outputDirectory = FileManager.default.temporaryDirectory
        .appending(path: "tokenbar-stats-snapshots", directoryHint: .isDirectory)

    @Test("sin selección, en claro y oscuro")
    func sinSeleccion() throws {
        try render(.light, selectedDay: nil, name: "semana-sin-seleccion-claro")
        try render(.dark, selectedDay: nil, name: "semana-sin-seleccion-oscuro")
    }

    @Test("con un día seleccionado, en claro y oscuro")
    func conSeleccion() throws {
        try render(.light, selectedDay: "2026-10-04", name: "semana-seleccion-claro")
        try render(.dark, selectedDay: "2026-10-04", name: "semana-seleccion-oscuro")
    }

    private func render(_ scheme: ColorScheme, selectedDay: String?, name: String) throws {
        let content = WeekSummaryView(snapshot: Self.snapshot, selectedDay: selectedDay)
            .frame(width: 276, alignment: .topLeading)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(
            NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        )
        try FileManager.default.createDirectory(
            at: Self.outputDirectory,
            withIntermediateDirectories: true
        )
        let url = Self.outputDirectory.appending(path: "\(name).png")
        try png.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(png.count > 2_000, "\(name).png salió vacío")
    }

    private static let snapshot: UsageSnapshot = {
        let days = [
            DayTotal(day: "2026-09-29", tokens: 50_000_000),
            DayTotal(day: "2026-09-30", tokens: 60_000_000),
            DayTotal(day: "2026-10-01", tokens: 70_000_000),
            DayTotal(day: "2026-10-02", tokens: 0),
            DayTotal(day: "2026-10-03", tokens: 80_000_000),
            DayTotal(day: "2026-10-04", tokens: 180_200_000),
            DayTotal(day: "2026-10-05", tokens: 49_300_000)
        ]
        return UsageSnapshot(
            todayByApp: [:],
            last7DaysByApp: [.claudeCode: days],
            todayTotalTokens: days.last?.tokens ?? 0,
            todayCostUSD: 0,
            currentStreak: 3,
            bestStreak: 8
        )
    }()
}
