import Foundation
import Fastlane

class Fastfile: LaneFile {

    // MARK: - Properties

    var appIdentifier: String { "com.lovelymusic.app" }
    var extensionIdentifier: String { "com.lovelymusic.app.NotificationService" }
    var xcodeproj: String { "LovelyMusic.xcodeproj" }
    var matchGitUrl: String { environmentVariable(get: "MATCH_GIT_URL") }

    // MARK: - CI: Test

    func testLane() {
        scan(
            project: .userDefined(xcodeproj),
            scheme: .userDefined("LovelyMusicTests"),
            device: .userDefined("iPhone 16"),
            clean: true,
            codeCoverage: .userDefined(true),
            outputDirectory: "fastlane/test_output"
        )
    }

    // MARK: - CD: Beta (TestFlight)

    func betaLane() {
        // 1. App Store Connect API Key (sets globally)
        appStoreConnectApiKey(
            keyId: environmentVariable(get: "APP_STORE_CONNECT_API_KEY_ID"),
            issuerId: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_ISSUER_ID")),
            keyContent: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_KEY_CONTENT")),
            isKeyContentBase64: .userDefined(true),
            inHouse: .userDefined(false)
        )

        // 2. Code Signing via Match
        // Use ProcessInfo to read env directly — environmentVariable(get:)
        // does not reliably forward non-FASTLANE_* vars to the Ruby subprocess.
        let readonly = ProcessInfo.processInfo.environment["MATCH_READONLY"]?.lowercased() != "false"
        let force = ProcessInfo.processInfo.environment["MATCH_FORCE"]?.lowercased() == "true" || !readonly
        let keychainPath = environmentVariable(get: "KEYCHAIN_PATH")
        let keychainPassword = environmentVariable(get: "KEYCHAIN_PASSWORD")
        let appIdentifiers = [appIdentifier, extensionIdentifier]

        if !keychainPath.isEmpty {
            syncCodeSigning(
                type: "appstore",
                readonly: .userDefined(readonly),
                appIdentifier: appIdentifiers,
                gitUrl: matchGitUrl,
                keychainName: keychainPath,
                keychainPassword: .userDefined(keychainPassword),
                force: .userDefined(force)
            )
        } else {
            syncCodeSigning(
                type: "appstore",
                readonly: .userDefined(readonly),
                appIdentifier: appIdentifiers,
                gitUrl: matchGitUrl,
                force: .userDefined(force)
            )
        }

        // 3. Build number (auto-increment from TestFlight)
        let currentBuildNumber = latestTestflightBuildNumber(
            appIdentifier: appIdentifier
        )
        incrementBuildNumber(
            buildNumber: .userDefined(String(currentBuildNumber + 1)),
            xcodeproj: .userDefined(xcodeproj)
        )

        // 4. Set version from tag (if provided via ENV)
        let appVersion = environmentVariable(get: "APP_VERSION")
        if !appVersion.isEmpty {
            incrementVersionNumber(
                versionNumber: .userDefined(appVersion),
                xcodeproj: .userDefined(xcodeproj)
            )
        }

        // 5. Build
        let envProfileName = environmentVariable(get: "sigh_\(appIdentifier)_appstore_profile-name")
        let profileSpecifier = envProfileName.isEmpty ? "match AppStore \(appIdentifier)" : envProfileName

        let envExtProfileName = environmentVariable(get: "sigh_\(extensionIdentifier)_appstore_profile-name")
        let extProfileSpecifier = envExtProfileName.isEmpty ? "match AppStore \(extensionIdentifier)" : envExtProfileName
        let teamId = environmentVariable(get: "APPLE_TEAM_ID")

        buildApp(
            project: .userDefined(xcodeproj),
            scheme: .userDefined("LovelyMusic"),
            clean: true,
            outputDirectory: "fastlane/output",
            outputName: .userDefined("LovelyMusic.ipa"),
            configuration: .userDefined("Release"),
            includeBitcode: .userDefined(false),
            exportMethod: .userDefined("app-store"),
            exportOptions: .userDefined([
                "signingStyle": "manual",
                "teamID": teamId,
                "provisioningProfiles": [
                    appIdentifier: profileSpecifier,
                    extensionIdentifier: extProfileSpecifier
                ]
            ]),
            destination: .userDefined("generic/platform=iOS"),
            xcargs: .userDefined("""
                DEVELOPMENT_TEAM=\(teamId) \
                CODE_SIGN_STYLE=Manual \
                CODE_SIGN_IDENTITY='Apple Distribution' \
                APP_PROVISIONING_PROFILE_SPECIFIER='\(profileSpecifier)' \
                EXT_PROVISIONING_PROFILE_SPECIFIER='\(extProfileSpecifier)'
            """),
            xcodebuildFormatter: ""
        )

        // 6. Upload to TestFlight
        uploadToTestflight(
            skipWaitingForBuildProcessing: .userDefined(true),
            distributeExternal: .userDefined(false)
        )
    }

    // MARK: - CD: Release (App Store)

    func releaseLane() {
        // 1. App Store Connect API Key
        appStoreConnectApiKey(
            keyId: environmentVariable(get: "APP_STORE_CONNECT_API_KEY_ID"),
            issuerId: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_ISSUER_ID")),
            keyContent: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_KEY_CONTENT")),
            isKeyContentBase64: .userDefined(true),
            inHouse: .userDefined(false)
        )

        // 2. Upload metadata + screenshots and submit for review
        // Note: skipBinaryUpload=true — reuses the latest TestFlight build
        uploadToAppStore(
            appIdentifier: .userDefined(appIdentifier),
            metadataPath: .userDefined("fastlane/metadata"),
            screenshotsPath: .userDefined("fastlane/screenshots"),
            skipBinaryUpload: .userDefined(true),
            skipScreenshots: .userDefined(false),
            skipMetadata: .userDefined(false),
            force: .userDefined(true),
            submitForReview: .userDefined(true),
            automaticRelease: .userDefined(false),
            submissionInformation: .userDefined([
                "add_id_info_uses_idfa": false
            ]),
            precheckIncludeInAppPurchases: .userDefined(false)
        )
    }

    // MARK: - Utility: Metadata Push

    func metadataLane() {
        // Upload metadata without submitting for review
        appStoreConnectApiKey(
            keyId: environmentVariable(get: "APP_STORE_CONNECT_API_KEY_ID"),
            issuerId: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_ISSUER_ID")),
            keyContent: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_KEY_CONTENT")),
            isKeyContentBase64: .userDefined(true),
            inHouse: .userDefined(false)
        )

        uploadToAppStore(
            appIdentifier: .userDefined(appIdentifier),
            metadataPath: .userDefined("fastlane/metadata"),
            skipBinaryUpload: .userDefined(true),
            skipScreenshots: .userDefined(true),
            force: .userDefined(true),
            submitForReview: .userDefined(false),
            automaticRelease: .userDefined(false),
            precheckIncludeInAppPurchases: .userDefined(false)
        )
    }

    // MARK: - Screenshots

    func snapshotLane() {
        captureScreenshots(
            project: .userDefined(xcodeproj),
            launchArguments: [
                "-FASTLANE_SNAPSHOT", "YES",
                "-hasCompletedOnboarding",
                "-AppleLanguages", "(en-US)",
                "-AppleLocale", "en_US",
            ],
            outputDirectory: "fastlane/screenshots",
            clearPreviousScreenshots: .userDefined(true),
            overrideStatusBar: .userDefined(true),
            overrideStatusBarArguments: .userDefined(
                "--time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4"
            ),
            scheme: .userDefined("LovelyMusicUITests")
        )
    }

    // MARK: - Utility Lanes

    func syncCertsLane() {
        let keyContent = environmentVariable(get: "APP_STORE_CONNECT_API_KEY_CONTENT")
        if !keyContent.isEmpty {
            appStoreConnectApiKey(
                keyId: environmentVariable(get: "APP_STORE_CONNECT_API_KEY_ID"),
                issuerId: .userDefined(environmentVariable(get: "APP_STORE_CONNECT_API_ISSUER_ID")),
                keyContent: .userDefined(keyContent),
                isKeyContentBase64: .userDefined(true),
                inHouse: .userDefined(false)
            )
        }
        syncCodeSigning(type: "appstore", appIdentifier: [appIdentifier, extensionIdentifier], gitUrl: matchGitUrl)
        syncCodeSigning(type: "development", appIdentifier: [appIdentifier, extensionIdentifier], gitUrl: matchGitUrl)
    }
}
