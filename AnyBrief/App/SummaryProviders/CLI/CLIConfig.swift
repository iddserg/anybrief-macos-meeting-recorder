import Foundation

/// opencode runs with a generated agent file that denies every tool by default.
/// Each flag here, when true, allows that specific operation for the agent.
struct OpencodePermissions: Codable, Equatable {
    var read = false
    var edit = false
    var glob = false
    var grep = false
    var list = false
    var bash = false
    var task = false
    var externalDirectory = false
    var todowrite = false
    var webfetch = false
    var websearch = false
    var lsp = false
    var skill = false
    var question = false
    var doomLoop = false

    static let allCases: [(WritableKeyPath<OpencodePermissions, Bool>, String, String)] = [
        (\.read, "read", "Read files"),
        (\.edit, "edit", "Edit files"),
        (\.glob, "glob", "List files by pattern"),
        (\.grep, "grep", "Search file contents"),
        (\.list, "list", "List directories"),
        (\.bash, "bash", "Run shell commands"),
        (\.task, "task", "Spawn subagents"),
        (\.externalDirectory, "external_directory", "Access outside the meeting folder"),
        (\.todowrite, "todowrite", "Write to-do lists"),
        (\.webfetch, "webfetch", "Fetch URLs"),
        (\.websearch, "websearch", "Web search"),
        (\.lsp, "lsp", "Language server access"),
        (\.skill, "skill", "Use skills"),
        (\.question, "question", "Ask clarifying questions"),
        (\.doomLoop, "doom_loop", "Loop detection override"),
    ]

    /// YAML frontmatter lines for the opencode agent's `permission:` map, one per flag.
    var yamlPermissionLines: String {
        Self.allCases
            .map { keyPath, key, _ in "  \(key): \(self[keyPath: keyPath] ? "allow" : "deny")" }
            .joined(separator: "\n")
    }
}

struct CLIConfig: Codable, Equatable {
    var commandPreset = CLIDefaults.preset
    var commandLine = ""
    /// codex `--sandbox` mode: "read-only" (default), "workspace-write", or "danger-full-access".
    var codexSandboxMode = "read-only"
    /// Prevent Codex from loading user plugins, MCP servers, and other user configuration.
    var codexIgnoreUserConfig = true
    /// Check the remote API before launching Codex or Claude CLI.
    var apiPreflightEnabled = true
    /// Verbatim value for claude's `--tools` flag. Empty denies every tool (default).
    var claudeAllowedTools = ""
    var opencodePermissions = OpencodePermissions()

    init(
        commandPreset: String = CLIDefaults.preset,
        commandLine: String = "",
        codexSandboxMode: String = "read-only",
        codexIgnoreUserConfig: Bool = true,
        apiPreflightEnabled: Bool = true,
        claudeAllowedTools: String = "",
        opencodePermissions: OpencodePermissions = OpencodePermissions()
    ) {
        self.commandPreset = commandPreset
        self.commandLine = commandLine
        self.codexSandboxMode = codexSandboxMode
        self.codexIgnoreUserConfig = codexIgnoreUserConfig
        self.apiPreflightEnabled = apiPreflightEnabled
        self.claudeAllowedTools = claudeAllowedTools
        self.opencodePermissions = opencodePermissions
    }

    private enum CodingKeys: String, CodingKey {
        case commandPreset
        case commandLine
        case codexSandboxMode
        case codexIgnoreUserConfig
        case apiPreflightEnabled
        case claudeAllowedTools
        case opencodePermissions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandPreset = try container.decodeIfPresent(String.self, forKey: .commandPreset) ?? CLIDefaults.preset
        commandLine = try container.decodeIfPresent(String.self, forKey: .commandLine) ?? ""
        codexSandboxMode = try container.decodeIfPresent(String.self, forKey: .codexSandboxMode) ?? "read-only"
        codexIgnoreUserConfig = try container.decodeIfPresent(Bool.self, forKey: .codexIgnoreUserConfig) ?? true
        apiPreflightEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiPreflightEnabled) ?? true
        claudeAllowedTools = try container.decodeIfPresent(String.self, forKey: .claudeAllowedTools) ?? ""
        opencodePermissions = try container.decodeIfPresent(
            OpencodePermissions.self,
            forKey: .opencodePermissions
        ) ?? OpencodePermissions()
    }
}

extension SummaryProviderConfiguration {
    static func cli(preset: String? = nil, commandLine: String = "") -> SummaryProviderConfiguration {
        var configuration = SummaryProviderConfiguration(provider: .commandLine)
        let trimmedCommand = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePreset = preset ?? (trimmedCommand.isEmpty ? CLIDefaults.preset : "custom")
        configuration.cliConfig = CLIConfig(
            commandPreset: effectivePreset,
            commandLine: commandLine
        )
        return configuration
    }

    var cliConfig: CLIConfig {
        get {
            ConfigurationPayloadCodec.decode(CLIConfig.self, from: payload, default: CLIConfig())
        }
        set {
            provider = .commandLine
            payload = ConfigurationPayloadCodec.encode(newValue)
        }
    }

    var cliEffectiveModel: String {
        ""
    }

    var cliCommandPreset: String {
        get { cliConfig.commandPreset }
        set {
            var config = cliConfig
            config.commandPreset = newValue
            cliConfig = config
        }
    }

    var cliCommandLine: String {
        get { cliConfig.commandLine }
        set {
            var config = cliConfig
            config.commandLine = newValue
            cliConfig = config
        }
    }

    var cliCodexSandboxMode: String {
        get { cliConfig.codexSandboxMode }
        set {
            var config = cliConfig
            config.codexSandboxMode = newValue
            cliConfig = config
        }
    }

    var cliCodexIgnoreUserConfig: Bool {
        get { cliConfig.codexIgnoreUserConfig }
        set {
            var config = cliConfig
            config.codexIgnoreUserConfig = newValue
            cliConfig = config
        }
    }

    var cliAPIPreflightEnabled: Bool {
        get { cliConfig.apiPreflightEnabled }
        set {
            var config = cliConfig
            config.apiPreflightEnabled = newValue
            cliConfig = config
        }
    }

    var cliClaudeAllowedTools: String {
        get { cliConfig.claudeAllowedTools }
        set {
            var config = cliConfig
            config.claudeAllowedTools = newValue
            cliConfig = config
        }
    }

    var cliOpencodePermissions: OpencodePermissions {
        get { cliConfig.opencodePermissions }
        set {
            var config = cliConfig
            config.opencodePermissions = newValue
            cliConfig = config
        }
    }
}
