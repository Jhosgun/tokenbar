import ServiceManagement
import Testing

@testable import TokenBar

@Suite("LaunchAtLogin")
struct LaunchAtLoginTests {

    @Test("registra cuando falta una decisión y el servicio no está registrado")
    func registraSinDecision() {
        #expect(LaunchAtLogin.shouldRegister(status: .notRegistered, decided: false))
    }

    @Test("no registra cuando ya existe una decisión")
    func respetaDecision() {
        #expect(!LaunchAtLogin.shouldRegister(status: .notRegistered, decided: true))
    }

    @Test("no registra un servicio habilitado")
    func noRegistraHabilitado() {
        #expect(!LaunchAtLogin.shouldRegister(status: .enabled, decided: false))
    }

    @Test("no registra un servicio pendiente de aprobación")
    func noRegistraPendienteDeAprobacion() {
        #expect(!LaunchAtLogin.shouldRegister(status: .requiresApproval, decided: false))
    }

    @Test("no registra un servicio que no existe")
    func noRegistraAusente() {
        #expect(!LaunchAtLogin.shouldRegister(status: .notFound, decided: false))
    }
}
