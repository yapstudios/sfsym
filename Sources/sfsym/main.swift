import Foundation

/// Emit a runtime error. When invoked with `--json`, emit `{"error", "code"}` to
/// stderr so agents that set that flag can parse errors uniformly. Usage-help
/// errors still render as plain text — those aren't structured conditions.
func emitRuntimeError(_ msg: String, code: String, exitCode: Int32) -> Never {
    if CommandLine.arguments.contains("--json") {
        let obj: [String: Any] = ["error": msg, "code": code]
        if let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]
        ) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
        }
    } else {
        FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    }
    exit(exitCode)
}

do {
    try runCLI()
} catch CLIError.usage(let msg) {
    FileHandle.standardError.write(Data(msg.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(64)
} catch CLIError.bad(let msg) {
    emitRuntimeError(msg, code: "bad_args", exitCode: 2)
} catch CLIError.io(let msg) {
    emitRuntimeError(msg, code: "io_error", exitCode: 2)
} catch GlyphError.notFound(let name) {
    emitRuntimeError("symbol not found: \(name)", code: "not_found", exitCode: 1)
} catch GlyphError.bad(let msg) {
    emitRuntimeError(msg, code: "render_error", exitCode: 2)
} catch {
    emitRuntimeError("\(error)", code: "internal_error", exitCode: 2)
}
