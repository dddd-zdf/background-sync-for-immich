import Foundation

/// Finds the app group shared by the app and the upload extension.
///
/// SideStore rewrites app group IDs at signing time (`group.X` becomes `group.X.<TEAMID>`),
/// so the compiled-in name is only a fallback. The real name is read from the
/// provisioning profile that SideStore embeds in each bundle.
enum AppGroup {
    static let declared = "group.com.difei.immichbackup"

    static let identifier: String = {
        for candidate in provisionedGroups() + [declared]
        where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
            return candidate
        }
        return declared
    }()

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// App groups listed in `embedded.mobileprovision`, preferring ones derived from ours.
    static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups.sorted { a, _ in a.hasPrefix(declared) }
    }
}
