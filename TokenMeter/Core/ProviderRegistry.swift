import Foundation

/// The single list of compiled-in Providers (ADR 0004). Adding a Provider means adding its
/// module under `TokenMeter/Providers/<Name>/` and one case here.
enum ProviderRegistry {
    /// How to read Accounts of `kind`, or nil when that Provider is not implemented yet.
    static func reader(for kind: ProviderKind) -> (any AccountReader)? {
        switch kind {
        case .ollama:
            CredentialedReader(provider: OllamaProvider.live,
                               source: OllamaProvider.credentialSource)
        case .claude:
            CredentialedReader(provider: ClaudeProvider.live,
                               source: ClaudeProvider.credentialSource)
        case .codex:
            CredentialedReader(provider: CodexProvider.live,
                               source: CodexProvider.credentialSource)
        case .copilot:
            CredentialedReader(provider: CopilotProvider.live,
                               source: CopilotProvider.credentialSource)
        case .nous:
            CredentialedReader(provider: NousProvider.live,
                               source: NousProvider.credentialSource)
        case .venice:
            CredentialedReader(provider: VeniceProvider.live,
                               source: VeniceProvider.credentialSource)
        case .zai:
            CredentialedReader(provider: ZaiProvider.live, source: ZaiProvider.credentialSource)
        case .xai:
            CredentialedReader(provider: XaiProvider.live, source: XaiProvider.credentialSource)
        case .cursor:
            CredentialedReader(provider: CursorProvider.live, source: CursorProvider.credentialSource)
        case .opencode:
            CredentialedReader(provider: OpenCodeProvider.live, source: OpenCodeProvider.credentialSource)
        case .alibaba:
            CredentialedReader(provider: AlibabaProvider.live, source: AlibabaProvider.credentialSource)
        case .gemini:
            CredentialedReader(provider: GeminiProvider.live, source: GeminiProvider.credentialSource)
        case .antigravity:
            CredentialedReader(provider: AntigravityProvider.live, source: AntigravityProvider.credentialSource)
        case .minimax:
            CredentialedReader(provider: MiniMaxProvider.live, source: MiniMaxProvider.credentialSource)
        case .kimi:
            CredentialedReader(provider: KimiProvider.live, source: KimiProvider.credentialSource)
        case .synthetic:
            CredentialedReader(provider: SyntheticProvider.live, source: SyntheticProvider.credentialSource)
        case .deepseek:
            CredentialedReader(provider: DeepSeekProvider.live, source: DeepSeekProvider.credentialSource)
        case .mistral:
            CredentialedReader(provider: MistralProvider.live, source: MistralProvider.credentialSource)
        case .xiaomi:
            CredentialedReader(provider: XiaomiProvider.live, source: XiaomiProvider.credentialSource)
        }
    }

    /// Providers offered by Settings' "Add Account" menu, in menu order.
    static var addable: [ProviderKind] {
        ProviderKind.allCases.filter { reader(for: $0) != nil }
    }

    /// DEBUG-only base-URL override for smoke runs against a local stub server,
    /// e.g. `TOKENMETER_OLLAMA_BASE_URL=http://127.0.0.1:8765`. Release builds always use the real host.
    static func debugBaseURL(_ variable: String) -> URL? {
        #if DEBUG
        ProcessInfo.processInfo.environment[variable].flatMap(URL.init(string:))
        #else
        nil
        #endif
    }
}
