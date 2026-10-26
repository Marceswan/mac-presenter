import Foundation
import Security
import Testing
@testable import Presenter

/// Sparkle settings and the sandbox entitlements it needs. The test host is the app.
@MainActor
struct UpdateConfigurationTests {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    private func entitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    @Test func feedAndPolicyKeys() {
        #expect(info["SUFeedURL"] as? String == "https://github.com/Marceswan/mac-presenter/releases/latest/download/appcast.xml")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
        #expect((info["SUScheduledCheckInterval"] as? NSNumber)?.intValue == 3600)
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        #expect(info["SUEnableDownloaderService"] as? Bool == true)
    }

    @Test func publicKeyIsA32ByteBase64Key() throws {
        let key = try #require(info["SUPublicEDKey"] as? String)
        let data = try #require(Data(base64Encoded: key))
        #expect(data.count == 32)
    }

    @Test func appCarriesSparkleLicenseNotice() throws {
        let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "html"))
        let credits = try String(contentsOf: url, encoding: .utf8)
        #expect(credits.contains("Sparkle"))
        #expect(credits.contains("Copyright (c) 2006-2013 Andy Matuschak."))
        #expect(credits.contains("Permission is hereby granted, free of charge"))
    }

    @Test func sandboxEntitlementsAllowSparkleWithoutNetwork() throws {
        #expect(entitlement("com.apple.security.app-sandbox") as? Bool == true)
        #expect(entitlement("com.apple.security.network.client") == nil)
        // Test builds add Xcode's own test-runner names to this list.
        let names = try #require(entitlement("com.apple.security.temporary-exception.mach-lookup.global-name") as? [String])
        #expect(Set(names).isSuperset(of: ["com.marcswan.Presenter-spks", "com.marcswan.Presenter-spki"]))
    }
}
