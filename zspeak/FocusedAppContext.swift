import Foundation

/// Classifica o app em foco em categorias de contexto de vocabulário.
///
/// A categoria decide quais entradas de vocabulário participam do biasing
/// nativo e das substituições alias→term na gravação corrente. `.global`
/// sempre participa; `.dev` só quando o app em foco é terminal/IDE/editor.
enum FocusedAppContext {

    /// Bundle IDs exatos de terminais, IDEs e editores de código.
    static let devBundleIDs: Set<String> = [
        // Terminais
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        // IDEs / editores
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "org.vim.MacVim",
        "com.neovide.neovide",
    ]

    /// Prefixos de bundle ID que cobrem famílias inteiras de apps dev.
    static let devBundleIDPrefixes: [String] = [
        "com.jetbrains.",   // IntelliJ, WebStorm, DataGrip, Rider, ...
        "com.google.android.studio",
    ]

    /// Categorias de vocabulário ativas para o app em foco.
    /// `nil`/desconhecido → só `.global` (postura conservadora: termos dev
    /// não interferem em prosa de e-mail/chat/notas).
    static func categories(forBundleID bundleID: String?) -> Set<VocabularyEntryContext> {
        guard let bundleID, isDevApp(bundleID: bundleID) else { return [.global] }
        return [.global, .dev]
    }

    static func isDevApp(bundleID: String) -> Bool {
        if devBundleIDs.contains(bundleID) { return true }
        return devBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }
}
