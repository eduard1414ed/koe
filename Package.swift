// swift-tools-version:6.2
// The Koe app: the menu bar icon, recording and transcription. menubar/build.sh builds it with
// `swift build -c release` and packs the result into an .app.
import PackageDescription

let package = Package(
    name: "Koe",
    // FluidAudio's speaker diarization crashes on macOS 14 (fixed in 15)
    platforms: [.macOS(.v15)],
    // Updates: built into the release only (build.sh release passes --traits Updates). The development build
    // doesn't even link Sparkle, so it never looks for updates. In the code: #if Updates.
    traits: [.trait(name: "Updates")],
    dependencies: [
        // the exact version: transcription results were checked against it when the engine was chosen.
        // Keep fluidAudioVersion in menubar/Engine.swift the same.
        // Traits: speech recognition, the speech detector and diarization only — no text-to-speech.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: ["Diarizer"]),
        // automatic updates (release only, see traits above); exact version, as with FluidAudio
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "KoeDev",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle", condition: .when(traits: ["Updates"])),
            ],
            path: "menubar",
            exclude: ["build.sh", "make_cert.sh", "dmg.sh", "appcast.sh", "Koe.entitlements", "dmg"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
