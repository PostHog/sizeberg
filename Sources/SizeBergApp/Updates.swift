import AppKit
import Security
import Sparkle

/// Updates through Sparkle: it reads the appcast of the latest GitHub release, checks the download's
/// EdDSA signature against the key in Info.plist and its Developer ID signature against this app's,
/// then installs it. Only a Developer ID signed build can prove the next build is the same app, so an
/// ad-hoc build, such as a local one, points to Homebrew instead.
@MainActor
final class Updates {
    static let shared = Updates()

    /// Nil for builds that cannot update themselves.
    private let controller: SPUStandardUpdaterController?

    private init() {
        let hasKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil
        controller = hasKey && Self.isDeveloperIDSigned
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "This build does not update itself"
        alert.informativeText = "Builds that are not signed with a Developer ID update with Homebrew:\n\nbrew upgrade --cask sizeberg"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A team identifier is present only in a signature made with a Developer ID; ad-hoc signatures have none.
    private static var isDeveloperIDSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] != nil
    }
}
