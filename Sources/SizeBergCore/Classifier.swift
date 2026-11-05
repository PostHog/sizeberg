import Darwin

/// Decides which bucket a directory belongs to from its name and its parent's bucket.
enum Classifier {
    static let dependencyNames: Set<String> = ["node_modules", ".venv", "venv"]

    static let buildNames: Set<String> = [
        ".mypy_cache", ".pytest_cache", "__pycache__", ".ruff_cache", ".hypothesis", ".tox", ".nox",
        ".turbo", ".next", ".nuxt", ".svelte-kit", ".parcel-cache", ".vite", ".nx",
        "storybook-static", "playwright-report", "test-results", "coverage", "htmlcov",
        "dist", "staticfiles", ".build", "DerivedData", ".gradle",
    ]

    static let cacheNames: Set<String> = [".cache"]

    /// Only these parts of .flox are rebuilt on activation; the rest, like env/manifest.toml, is checked in.
    static let floxCacheNames: Set<String> = ["cache", "log"]

    static func kind(
        forDirectory name: String,
        parent: BucketKind,
        path: String
    ) -> BucketKind {
        switch parent {
        case .dependencies, .buildOutput, .git:
            return parent
        case .source, .caches:
            break
        }
        // A venv inside a tool cache (for example .flox/cache/venv) is still dependencies.
        if dependencyNames.contains(name) {
            return .dependencies
        }
        if parent == .caches {
            return .caches
        }
        if name == ".git" {
            return .git
        }
        if buildNames.contains(name) {
            return .buildOutput
        }
        if name == "target", hasCargoManifestBeside(path) {
            return .buildOutput
        }
        if cacheNames.contains(name) {
            return .caches
        }
        if floxCacheNames.contains(name), path.hasSuffix("/.flox/" + name) {
            return .caches
        }
        return .source
    }

    private static func hasCargoManifestBeside(_ path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return false }
        let manifest = path[..<slash] + "/Cargo.toml"
        return access(String(manifest), F_OK) == 0
    }
}
