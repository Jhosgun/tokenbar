import Darwin
import Foundation

/// Resultado de leer una contraseña genérica con `/usr/bin/security`. La credencial
/// (o el fallo) nunca se expone en logs ni se persiste; viaja solo entre el subproceso y
/// el proveedor.
enum KeychainCredentialReadResult: Equatable, Sendable {
    case credential(String)
    case notFound
    case denied
    case locked
    case timedOut
    case failed
}

typealias ClaudeCredentialReadResult = KeychainCredentialReadResult

/// Salida cruda del subproceso `security`, solo para clasificarla en un
/// `ClaudeCredentialReadResult`. La credencial va en `stdout` y se descarta enseguida.
struct SecurityCommandOutput: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32?
    var timedOut: Bool
}

/// Lee una contraseña genérica ejecutando `/usr/bin/security` en un subproceso, sin
/// diálogo, con timeout propio y `kill` si no termina.
actor KeychainCredentialReader {
    typealias Runner = @Sendable () async -> SecurityCommandOutput

    private let run: Runner
    private var denied = false

    init(service: String, account: String? = nil, run: Runner? = nil) {
        if let run {
            self.run = run
        } else {
            self.run = {
                await SecurityProcessRun(service: service, account: account, timeout: 2).start()
            }
        }
    }

    func read() async -> KeychainCredentialReadResult {
        if denied { return .denied }
        let result = Self.classify(await run())
        if result == .denied { denied = true }
        return result
    }

    static func classify(_ output: SecurityCommandOutput) -> KeychainCredentialReadResult {
        if output.timedOut { return .timedOut }
        if output.exitCode == 0 {
            let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .failed : .credential(value)
        }
        if output.exitCode == 44 { return .notFound }
        if output.exitCode == 51 { return .locked }

        let error = output.stderr.lowercased()
        if error.contains("user canceled") || error.contains("user cancelled")
            || error.contains("authorization denied") || error.contains("deneg") {
            return .denied
        }
        if error.contains("interaction is not allowed") || error.contains("keychain is locked")
            || error.contains("llavero está bloqueado") || error.contains("llavero esta bloqueado") {
            return .locked
        }
        if error.contains("could not be found") || error.contains("no se encontr") {
            return .notFound
        }
        return .failed
    }
}

/// Fachada de Claude Code sobre el lector genérico. La entrada ajena
/// (`Claude Code-credentials`) se lee con `security`, que ya está en su lista de acceso.
actor ClaudeCredentialReader {
    typealias Runner = KeychainCredentialReader.Runner

    private let reader: KeychainCredentialReader

    init(run: Runner? = nil) {
        reader = KeychainCredentialReader(service: "Claude Code-credentials", run: run)
    }

    func read() async -> ClaudeCredentialReadResult {
        await reader.read()
    }

    static func classify(_ output: SecurityCommandOutput) -> ClaudeCredentialReadResult {
        KeychainCredentialReader.classify(output)
    }
}

/// Ejecuta `security find-generic-password` en un subproceso y lo mata si supera el
/// timeout, sin bloquear un hilo cooperativo.
private final class SecurityProcessRun: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SecurityCommandOutput, Never>?
    private var timedOut = false

    init(service: String, account: String?, timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        arguments.append("-w")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() async -> SecurityCommandOutput {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .utility).async { [self] in
                process.terminationHandler = { [self] process in
                    process.terminationHandler = nil
                    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    lock.lock()
                    let didTimeOut = timedOut
                    lock.unlock()
                    finish(SecurityCommandOutput(stdout: out, stderr: error,
                                                 exitCode: process.terminationStatus,
                                                 timedOut: didTimeOut))
                }

                do {
                    try process.run()
                } catch {
                    finish(SecurityCommandOutput(stdout: "", stderr: "", exitCode: nil, timedOut: false))
                    return
                }

                // El timeout corre en paralelo al subproceso: si este no termina, se le
                // pide la salida con `terminate` y, 0,2 s después, un SIGKILL de respaldo.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                    guard process.isRunning else { return }
                    lock.lock()
                    timedOut = true
                    lock.unlock()
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [self] in
                        if process.isRunning {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        }
    }

    private func finish(_ output: SecurityCommandOutput) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: output)
    }
}
