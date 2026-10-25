import Foundation

public enum OpenCodeGoSettingsReader {
    public static let apiKeyEnvironmentKey = "OPENCODE_API_KEY"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    static func tokenAccountAPIKey(_ raw: String) -> String? {
        guard let value = SettingsValue.cleaned(raw),
              !value.contains(where: { $0.isWhitespace || $0 == "=" || $0 == ":" })
        else { return nil }
        return value
    }

    static func workspaceID(context: ProviderFetchContext) -> String? {
        SettingsValue.cleaned(context.settings?.opencodego?.workspaceID)
            ?? SettingsValue.cleaned(context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"])
    }

    static func isExplicitlyScoped(context: ProviderFetchContext) -> Bool {
        context.selectedTokenAccountID != nil || context.settings?.opencodego?.cookieSource == .manual ||
            self.workspaceID(context: context) != nil
    }
}
