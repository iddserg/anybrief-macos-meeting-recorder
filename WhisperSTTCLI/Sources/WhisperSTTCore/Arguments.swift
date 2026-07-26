import Foundation

public enum WhisperSTTError: LocalizedError, Equatable {
    case usage(String)
    case fileNotFound(String)
    case processFailed(name: String, status: Int32)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message):
            message
        case .fileNotFound(let path):
            "File not found: \(path)"
        case .processFailed(let name, let status):
            "\(name) exited with status \(status)"
        case .invalidOutput(let detail):
            detail
        }
    }
}

public struct WhisperSTTOptions: Equatable, Sendable {
    public var inputFile: String
    public var outputDirectory: String?
    public var verbose = false
    public var transcribeOnly = false
    public var batchFirst = false
    public var threshold = 0.65
    public var speakers = -1
    public var speakerMax: Int?
    public var model: String
    public var language = "auto"
    public var threads: Int?
    public var noGPU = false
    public var sttPath: String?
    public var whisperCorePath: String?
    public var vadModelPath: String?
    public var diarizationJSONPath: String?
    public var whisperJSONPath: String?
    public var vocabularyFile: String?

    public init(inputFile: String, model: String) {
        self.inputFile = inputFile
        self.model = model
    }
}

public enum WhisperSTTArguments {
    public static let help = """
    OVERVIEW: Full-pass whisper.cpp transcription with FluidAudio speaker diarization.

    USAGE: whisper-stt <input-file> [options]

    ARGUMENTS:
      <input-file>                    Input WAV, MP3, M4A, or FLAC file

    OPTIONS:
      -o, --output <directory>        Output directory (default: input directory)
      -v, --verbose                   Print subprocess output
          --transcribe-only           Skip FluidAudio diarization
          --batch-first               Accepted for stt CLI compatibility
          --threshold <0...1>         FluidAudio clustering threshold (default: 0.65)
          --speakers <-1|N>           Expected speaker count (default: -1)
          --speaker-max <N>           Maximum speaker count; fewer are allowed
      -m, --model <file>              ggml Whisper model (or WHISPER_MODEL)
      -l, --language <code>           Language code or auto (default: auto)
      -t, --threads <count>           whisper.cpp worker threads
          --no-gpu                    Disable Metal and run whisper.cpp on CPU
          --stt <file>                stt executable with --diarize-only support
          --whisper-core <file>       whisper-cli executable
          --vad-model <file>          Silero VAD model for filtering non-speech
          --diarization-json <file>   Reuse an existing FluidAudio JSON
          --whisper-json <file>       Reuse an existing whisper.cpp full JSON
          --vocabulary-file <file>    Preferred terms, one per line; aliases follow a colon
      -h, --help                      Show this help
    """

    public static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> WhisperSTTOptions? {
        if arguments.contains("-h") || arguments.contains("--help") {
            return nil
        }

        var input: String?
        var output: String?
        var verbose = false
        var transcribeOnly = false
        var batchFirst = false
        var threshold = 0.65
        var speakers = -1
        var speakerMax: Int?
        var model = environment["WHISPER_MODEL"]
        var language = "auto"
        var threads: Int?
        var noGPU = false
        var sttPath = environment["WHISPER_STT_DIARIZER"]
        var whisperCorePath = environment["WHISPER_CPP_CORE"]
        var vadModelPath = environment["WHISPER_VAD_MODEL"]
        var diarizationJSONPath: String?
        var whisperJSONPath: String?
        var vocabularyFile: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if !argument.hasPrefix("-"), input == nil {
                input = argument
                index += 1
                continue
            }

            switch argument {
            case "-v", "--verbose":
                verbose = true
            case "--transcribe-only":
                transcribeOnly = true
            case "--batch-first":
                batchFirst = true
            case "--no-gpu":
                noGPU = true
            default:
                let (name, inlineValue) = split(argument)
                switch name {
                case "-o", "--output":
                    output = try value(inlineValue, arguments, &index, name)
                case "--threshold":
                    let raw = try value(inlineValue, arguments, &index, name)
                    guard let parsed = Double(raw), (0...1).contains(parsed) else {
                        throw WhisperSTTError.usage("threshold must be between 0.0 and 1.0")
                    }
                    threshold = parsed
                case "--speakers":
                    let raw = try value(inlineValue, arguments, &index, name)
                    guard let parsed = Int(raw), parsed == -1 || parsed > 0 else {
                        throw WhisperSTTError.usage("speakers must be -1 or a positive integer")
                    }
                    speakers = parsed
                case "--speaker-max", "--speakerMax":
                    let raw = try value(inlineValue, arguments, &index, name)
                    guard let parsed = Int(raw), parsed > 0 else {
                        throw WhisperSTTError.usage("speaker-max must be a positive integer")
                    }
                    speakerMax = parsed
                case "-m", "--model":
                    model = try value(inlineValue, arguments, &index, name)
                case "-l", "--language":
                    language = try value(inlineValue, arguments, &index, name)
                case "-t", "--threads":
                    let raw = try value(inlineValue, arguments, &index, name)
                    guard let parsed = Int(raw), parsed > 0 else {
                        throw WhisperSTTError.usage("threads must be a positive integer")
                    }
                    threads = parsed
                case "--stt":
                    sttPath = try value(inlineValue, arguments, &index, name)
                case "--whisper-core":
                    whisperCorePath = try value(inlineValue, arguments, &index, name)
                case "--vad-model":
                    vadModelPath = try value(inlineValue, arguments, &index, name)
                case "--diarization-json":
                    diarizationJSONPath = try value(inlineValue, arguments, &index, name)
                case "--whisper-json":
                    whisperJSONPath = try value(inlineValue, arguments, &index, name)
                case "--vocabulary-file":
                    vocabularyFile = try value(inlineValue, arguments, &index, name)
                default:
                    throw WhisperSTTError.usage("Unknown option: \(argument)")
                }
            }
            index += 1
        }

        guard let input else {
            throw WhisperSTTError.usage("Missing input audio file")
        }
        guard let model, !model.isEmpty else {
            throw WhisperSTTError.usage("Missing --model (or WHISPER_MODEL)")
        }
        guard speakers == -1 || speakerMax == nil else {
            throw WhisperSTTError.usage("--speakers and --speaker-max cannot be used together")
        }

        var options = WhisperSTTOptions(inputFile: input, model: model)
        options.outputDirectory = output
        options.verbose = verbose
        options.transcribeOnly = transcribeOnly
        options.batchFirst = batchFirst
        options.threshold = threshold
        options.speakers = speakers
        options.speakerMax = speakerMax
        options.language = language
        options.threads = threads
        options.noGPU = noGPU
        options.sttPath = sttPath
        options.whisperCorePath = whisperCorePath
        options.vadModelPath = vadModelPath
        options.diarizationJSONPath = diarizationJSONPath
        options.whisperJSONPath = whisperJSONPath
        options.vocabularyFile = vocabularyFile
        return options
    }

    private static func split(_ argument: String) -> (String, String?) {
        guard let separator = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        return (
            String(argument[..<separator]),
            String(argument[argument.index(after: separator)...])
        )
    }

    private static func value(
        _ inlineValue: String?,
        _ arguments: [String],
        _ index: inout Int,
        _ option: String
    ) throws -> String {
        if let inlineValue {
            return inlineValue
        }
        guard index + 1 < arguments.count else {
            throw WhisperSTTError.usage("Missing value for \(option)")
        }
        index += 1
        return arguments[index]
    }
}
