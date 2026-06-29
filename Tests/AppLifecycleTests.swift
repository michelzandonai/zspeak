import AppKit
import Testing
@testable import zspeak

@MainActor
@Suite("App lifecycle")
struct AppLifecycleTests {

    @Test("Aparencia do AppKit e aplicada somente apos didFinishLaunching")
    func testAppearanceIsDeferredUntilApplicationDidFinishLaunching() {
        ZSpeakAppDelegate.onDidFinishLaunching = nil
        defer { ZSpeakAppDelegate.onDidFinishLaunching = nil }

        var appliedAppearance: NSAppearance?
        var activationPolicy: NSApplication.ActivationPolicy?
        let installer = AppAppearanceInstaller { appearance in
            appliedAppearance = appearance
        }
        let dockInstaller = AppDockIconInstaller { policy in
            activationPolicy = policy
            return true
        }
        let delegate = ZSpeakAppDelegate(
            appearanceInstaller: installer,
            dockIconInstaller: dockInstaller
        )

        #expect(appliedAppearance == nil)
        #expect(activationPolicy == nil)

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        #expect(appliedAppearance?.name == .darkAqua)
        #expect(activationPolicy == .regular)
    }

    @Test("Presenter de configuracoes seleciona pagina, ativa app e mostra janela")
    func testSettingsPresenterShowsRequestedPage() {
        var selectedPage: String?
        var didShowDockIcon = false
        var didActivateApplication = false
        var didShowWindow = false

        let presenter = SettingsWindowPresenter(
            setInitialPage: { page in selectedPage = page },
            showDockIcon: { didShowDockIcon = true },
            activateApplication: { didActivateApplication = true },
            showWindow: { didShowWindow = true }
        )

        presenter.show(.permissions)

        #expect(selectedPage == SettingsPage.permissions.rawValue)
        #expect(didShowDockIcon)
        #expect(didActivateApplication)
        #expect(didShowWindow)
    }

    @Test("Startup abre configuracoes na pagina inicial")
    func testStartupWindowPresenterShowsSettingsOverview() {
        var openedPage: SettingsPage?

        let presenter = StartupWindowPresenter(showSettings: { page in
            openedPage = page
        })

        presenter.showInitialWindow()

        #expect(openedPage?.rawValue == SettingsPage.overview.rawValue)
    }
}
