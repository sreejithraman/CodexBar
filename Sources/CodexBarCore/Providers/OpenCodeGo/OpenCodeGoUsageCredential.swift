import Foundation

struct OpenCodeGoUsageCredential: Sendable {
    typealias CLICredentialLoader = @Sendable (ProviderFetchContext) throws -> String?

    enum Source: String {
        case api
        case cli
    }

    let token: String
    let source: Source

    static func resolve(
        context: ProviderFetchContext,
        cliCredentialLoader: CLICredentialLoader) throws -> Self?
    {
        if let apiKey = OpenCodeGoSettingsReader.apiKey(environment: context.env) {
            return Self(token: apiKey, source: .api)
        }
        guard context.sourceMode != .web,
              !OpenCodeGoSettingsReader.isExplicitlyScoped(context: context)
        else { return nil }
        return try cliCredentialLoader(context).map { Self(token: $0, source: .cli) }
    }

    static func loadCLI(context: ProviderFetchContext) throws -> String? {
        try OpenCodeGoCLICredentialsReader(environment: context.env).load()
    }
}
