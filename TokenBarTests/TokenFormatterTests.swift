import Foundation
import Testing

@testable import TokenBar

@Suite("TokenFormatter")
struct TokenFormatterTests {

    // MARK: - short

    @Test("valores menores a 1000 van sin sufijo")
    func cortoSinSufijo() {
        #expect(TokenFormatter.short(0) == "0")
        #expect(TokenFormatter.short(1) == "1")
        #expect(TokenFormatter.short(950) == "950")
        #expect(TokenFormatter.short(999) == "999")
    }

    @Test("desde 1000 usa sufijo K con un decimal que conserva el .0")
    func cortoEnMiles() {
        #expect(TokenFormatter.short(1_000) == "1.0K")
        #expect(TokenFormatter.short(1_050) == "1.1K")
        #expect(TokenFormatter.short(12_000) == "12.0K")
        #expect(TokenFormatter.short(12_400) == "12.4K")
        #expect(TokenFormatter.short(12_449) == "12.4K")
        #expect(TokenFormatter.short(999_499) == "999.5K")
    }

    @Test("el redondeo half-up que desborda la escala sube de unidad")
    func cortoDesbordaEscala() {
        // 999_999 redondea a 1000.0K, que debe reportarse como 1.0M.
        #expect(TokenFormatter.short(999_999) == "1.0M")
        #expect(TokenFormatter.short(999_999_999) == "1.0B")
    }

    @Test("millones y miles de millones")
    func cortoEnMillones() {
        #expect(TokenFormatter.short(1_000_000) == "1.0M")
        #expect(TokenFormatter.short(1_200_000) == "1.2M")
        #expect(TokenFormatter.short(1_250_000) == "1.3M")
        #expect(TokenFormatter.short(1_000_000_000) == "1.0B")
        #expect(TokenFormatter.short(1_234_000_000) == "1.2B")
    }

    @Test("los negativos llevan prefijo - y la misma magnitud")
    func cortoNegativos() {
        #expect(TokenFormatter.short(-1) == "-1")
        #expect(TokenFormatter.short(-950) == "-950")
        #expect(TokenFormatter.short(-12_400) == "-12.4K")
        #expect(TokenFormatter.short(-1_200_000) == "-1.2M")
    }

    @Test("cero no lleva signo")
    func ceroSinSigno() {
        #expect(TokenFormatter.short(0) == "0")
        #expect(!TokenFormatter.short(0).hasPrefix("-"))
    }

    // MARK: - currency

    @Test("costos con dos decimales")
    func monedaNormal() {
        #expect(TokenFormatter.currency(1.234) == "$1.23")
        #expect(TokenFormatter.currency(1.0) == "$1.00")
        #expect(TokenFormatter.currency(0.01) == "$0.01")
        #expect(TokenFormatter.currency(1234.5) == "$1234.50")
    }

    @Test("cero exacto es $0.00")
    func monedaCero() {
        #expect(TokenFormatter.currency(0) == "$0.00")
    }

    @Test("mayor que cero pero menor a un centavo se muestra como <$0.01")
    func monedaMinima() {
        #expect(TokenFormatter.currency(0.004) == "<$0.01")
        #expect(TokenFormatter.currency(0.0000001) == "<$0.01")
        #expect(TokenFormatter.currency(0.009999) == "<$0.01")
    }
}
