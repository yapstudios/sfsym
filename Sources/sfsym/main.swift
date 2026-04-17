import Foundation

do {
    try runCLI()
} catch CLIError.usage(let msg) {
    FileHandle.standardError.write(Data(msg.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(64)
} catch CLIError.bad(let msg) {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(2)
} catch GlyphError.notFound(let name) {
    FileHandle.standardError.write(Data("symbol not found: \(name)\n".utf8))
    exit(1)
} catch GlyphError.bad(let msg) {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}
