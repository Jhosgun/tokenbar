import AppKit
import ServiceManagement
import SwiftUI

/// Ventana de preferencias (id `preferences`). Se abre desde el menú ⚙︎ del dashboard.
struct PreferencesView: View {

    private static let cursorTokenKey = "cursor.sessionToken"
    private static let dataPathLabel = "~/Library/Application Support/TokenBar"

    @Bindable private var viewModel: UsageViewModel

    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var cursorToken = ""
    @State private var hasStoredToken = false

    @State private var notifier = ThresholdNotifier()
    // Se leen en la construcción de la vista, no en `onAppear`: así el `onChange`
    // del toggle no se dispara al sincronizar y no pide permisos sin que el usuario lo pida.
    @State private var notifyEnabled = ThresholdNotifier.isEnabled
    @State private var threshold = ThresholdNotifier.threshold

    init(viewModel: UsageViewModel) {
        self._viewModel = Bindable(viewModel)
    }

    var body: some View {
        Form {
            generalSection
            notificationsSection
            cursorSection
            dataSection
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .onAppear(perform: loadCurrentState)
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Mostrar costo estimado", isOn: $viewModel.showCost)

            Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    applyLaunchAtLogin(newValue)
                }

            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Registra o desregistra el arranque automático. Un fallo nunca tumba la app:
    /// se muestra el error y el toggle vuelve al estado real del sistema.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        // Evita re-actuar cuando el toggle solo se está sincronizando con el sistema.
        guard (service.status == .enabled) != enabled else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchError = nil
        } catch {
            launchError = "No se pudo cambiar el arranque automático: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }

    // MARK: - Notificaciones

    private var notificationsSection: some View {
        Section("Notificaciones") {
            Toggle("Avisarme al superar un umbral diario", isOn: $notifyEnabled)
                .onChange(of: notifyEnabled) { _, newValue in
                    ThresholdNotifier.isEnabled = newValue
                    if newValue {
                        Task { await notifier.requestAuthorizationIfNeeded() }
                    }
                }

            if notifyEnabled {
                TextField("Umbral diario (tokens)", value: $threshold, format: .number)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: threshold) { _, newValue in
                        applyThreshold(newValue)
                    }

                Text("Se avisa al pasar \(TokenFormatter.short(threshold)) tokens hoy. Solo una notificación por día.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Persiste el umbral solo si es válido. Basura o cero revierten al último valor guardado.
    private func applyThreshold(_ newValue: Int) {
        guard newValue > 0 else {
            threshold = ThresholdNotifier.threshold
            return
        }
        ThresholdNotifier.threshold = newValue
    }

    // MARK: - Cursor

    private var cursorSection: some View {
        Section("Cursor") {
            SecureField(
                "Token de sesión",
                text: $cursorToken,
                prompt: Text(hasStoredToken ? "•••• guardado" : "WorkosCursorSessionToken")
            )

            Text("Sácalo de la cookie WorkosCursorSessionToken en cursor.com (DevTools → Application → Cookies).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("La cuota se lee de endpoints internos de cursor.com usando tu sesión.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Guardar", action: saveCursorToken)
                    .disabled(trimmedToken.isEmpty)

                Button("Borrar", role: .destructive, action: clearCursorToken)
                    .disabled(!hasStoredToken)
            }
        }
    }

    private var trimmedToken: String {
        cursorToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveCursorToken() {
        let value = trimmedToken
        guard !value.isEmpty else { return }
        Keychain.set(value, forKey: Self.cursorTokenKey)
        // No se deja el token en memoria de la vista una vez guardado.
        cursorToken = ""
        hasStoredToken = true
    }

    private func clearCursorToken() {
        Keychain.set(nil, forKey: Self.cursorTokenKey)
        cursorToken = ""
        hasStoredToken = false
    }

    // MARK: - Datos

    private var dataSection: some View {
        Section("Datos") {
            HStack {
                Text(Self.dataPathLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Button("Mostrar en Finder", action: revealDataDirectory)
            }
        }
    }

    private func revealDataDirectory() {
        let directory = UsageStore.defaultDirectory
        NSWorkspace.shared.selectFile(
            directory.path,
            inFileViewerRootedAtPath: directory.deletingLastPathComponent().path
        )
    }

    // MARK: - Estado inicial

    private func loadCurrentState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hasStoredToken = Keychain.get(forKey: Self.cursorTokenKey)?.isEmpty == false
        cursorToken = ""
    }
}

#Preview {
    PreferencesView(
        viewModel: UsageViewModel(store: UsageStore(),
                                  state: CollectorStateStore(),
                                  collectors: [])
    )
}
