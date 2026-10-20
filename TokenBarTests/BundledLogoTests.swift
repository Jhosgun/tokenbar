import AppKit
import Testing

@testable import TokenBar

@Suite("Logos empaquetados")
struct BundledLogoTests {

    /// Image sets que deben viajar en el bundle de la app.
    private static let nombres = ["LogoOpenCode", "LogoAntigravity", "LogoCommandCode"]

    /// El bundle de la app anfitriona: los tests corren con `TEST_HOST = TokenBar.app`, así
    /// que el catálogo compilado está ahí y no en el `.xctest`.
    private static func bundleDeLaApp() -> Bundle? {
        if let app = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix("TokenBar.app") }) {
            return app
        }
        return Bundle.main.bundleIdentifier == "io.github.jhosgun.tokenbar" ? Bundle.main : nil
    }

    @Test("los tres image sets viajan en la app y cargan como NSImage")
    func losTresCargar() throws {
        let bundle = try #require(Self.bundleDeLaApp())
        for nombre in Self.nombres {
            let image = try #require(bundle.image(forResource: nombre),
                                     "Falta el image set \(nombre) en el bundle de la app")
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }
}
