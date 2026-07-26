import Darwin
import Foundation
import WhisperSTTCore

setbuf(stdout, nil)
setbuf(stderr, nil)

do {
    guard let options = try WhisperSTTArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
        print(WhisperSTTArguments.help)
        exit(EXIT_SUCCESS)
    }
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    try WhisperSTTRunner().run(options: options, ownExecutableURL: executableURL)
    print("Processing complete.")
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
