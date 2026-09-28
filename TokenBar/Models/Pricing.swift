import Foundation

/// Tarifas de un modelo, en USD por millón de tokens.
struct ModelPricing: Sendable {
    var inputPerMTok: Double
    var outputPerMTok: Double
    var cacheWritePerMTok: Double
    var cacheReadPerMTok: Double
}

/// Tabla de precios y cálculo de costo estimado.
enum Pricing {
    // Tarifas públicas de la API de Anthropic (USD por millón de tokens).
    // cacheWrite = 1.25x input (TTL 5 min); cacheRead = 0.1x input.
    static let fable = ModelPricing(inputPerMTok: 10.00, outputPerMTok: 50.00,
                                    cacheWritePerMTok: 12.50, cacheReadPerMTok: 1.00)
    static let opus = ModelPricing(inputPerMTok: 5.00, outputPerMTok: 25.00,
                                   cacheWritePerMTok: 6.25, cacheReadPerMTok: 0.50)
    static let sonnet = ModelPricing(inputPerMTok: 3.00, outputPerMTok: 15.00,
                                     cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30)
    static let haiku = ModelPricing(inputPerMTok: 1.00, outputPerMTok: 5.00,
                                    cacheWritePerMTok: 1.25, cacheReadPerMTok: 0.10)

    /// Match por substring del id de modelo, case-insensitive.
    /// Orden: haiku → fable/mythos → sonnet → opus. Devuelve nil si no hay tarifa conocida
    /// (ej. `<synthetic>`, que además siempre trae usage en cero).
    static func pricing(forModel model: String) -> ModelPricing? {
        let id = model.lowercased()
        if id.contains("haiku") { return haiku }
        if id.contains("fable") || id.contains("mythos") { return fable }
        if id.contains("sonnet") { return sonnet }
        if id.contains("opus") { return opus }
        return nil
    }

    /// Costo en USD. Si el modelo es desconocido devuelve 0.
    static func cost(model: String, inputTokens: Int, outputTokens: Int,
                     cacheCreationTokens: Int, cacheReadTokens: Int) -> Double {
        guard let rate = pricing(forModel: model) else { return 0 }
        let total = Double(inputTokens) * rate.inputPerMTok
            + Double(outputTokens) * rate.outputPerMTok
            + Double(cacheCreationTokens) * rate.cacheWritePerMTok
            + Double(cacheReadTokens) * rate.cacheReadPerMTok
        return total / 1_000_000
    }
}
