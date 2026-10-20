import AppKit
import ServiceManagement
import SwiftUI

/// Ventana de preferencias (id `preferences`). Se abre desde el menú ⚙︎ del dashboard.
struct PreferencesView: View {

    private static let dataPathLabel = "~/Library/Application Support/TokenBar"

    @Bindable private var viewModel: UsageViewModel

    @State private var launchAtLogin = false
    @State private var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @State private var launchError: String?

    @State private var notifier = ThresholdNotifier()
    // Se leen en la construcción de la vista, no en `onAppear`: así el `onChange`
    // del toggle no se dispara al sincronizar y no pide permisos sin que el usuario lo pida.
    @State private var notifyEnabled = ThresholdNotifier.isEnabled
    @State private var threshold = ThresholdNotifier.threshold
    @State private var permissionStatus: ThresholdNotifier.PermissionStatus = .notDetermined

    init(viewModel: UsageViewModel) {
        self._viewModel = Bindable(viewModel)
    }

    var body: some View {
        Form {
            generalSection
            notificationsSection
            dataSection
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .onAppear(perform: loadCurrentState)
        // Al volver de Ajustes del sistema los permisos pudieron cambiar.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLoginStatus()
            Task { await refreshPermissionStatus() }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Mostrar costo estimado", isOn: $viewModel.showCost)

            Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    applyLaunchAtLogin(newValue)
                }

            if launchAtLoginStatus == .requiresApproval {
                Text("macOS pide aprobarlo en Ajustes del Sistema → General → Elementos de inicio")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Abrir Ajustes") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .controlSize(.small)
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
        LaunchAtLogin.hasUserDecision = true

        do {
            if LaunchAtLogin.shouldRegister(status: service.status, decided: !enabled) {
                try service.register()
            } else if !enabled {
                try service.unregister()
            }
            launchError = nil
        } catch {
            launchError = "No se pudo cambiar el arranque automático: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    // MARK: - Notificaciones

    private var notificationsSection: some View {
        Section("Notificaciones") {
            Toggle("Avisarme al superar un umbral diario", isOn: $notifyEnabled)
                .onChange(of: notifyEnabled) { _, newValue in
                    ThresholdNotifier.isEnabled = newValue
                    Task {
                        // Se espera el diálogo del sistema antes de releer el permiso: si no,
                        // la lectura vería `.notDetermined` y nunca mostraría el rechazo.
                        if newValue { await notifier.requestAuthorization() }
                        await refreshPermissionStatus()
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

                if permissionStatus == .denied {
                    Label("Permiso denegado", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Button("Abrir Ajustes del sistema", action: openNotificationSettings)
                        .controlSize(.small)
                }
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

    private func refreshPermissionStatus() async {
        permissionStatus = await notifier.permissionStatus()
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
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
        refreshLaunchAtLoginStatus()
        Task { await refreshPermissionStatus() }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
        launchAtLogin = launchAtLoginStatus == .enabled
    }
}

#Preview {
    PreferencesView(
        viewModel: UsageViewModel(store: UsageStore(),
                                  state: CollectorStateStore(),
                                  collectors: [])
    )
}
