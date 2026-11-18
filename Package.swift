// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tutun",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TutunShared", targets: ["TutunShared"]),
        .executable(name: "Tutun", targets: ["TutunApp"]),
        .executable(name: "tutund", targets: ["tutund"]),
        .executable(name: "tutun-drop", targets: ["tutun-drop"]),
    ],
    targets: [
        .target(name: "TutunShared"),
        .target(name: "TutunCore", dependencies: ["TutunShared"]),
        .target(name: "TutunSystem", dependencies: ["TutunCore"]),
        .executableTarget(name: "tutund", dependencies: ["TutunCore", "TutunSystem"]),
        // Сброс прав перед запуском ядер с конфигами от провайдера (xray, вспомогательный sing-box).
        .executableTarget(name: "tutun-drop"),
        .executableTarget(name: "TutunApp", dependencies: ["TutunCore"]),
        .testTarget(name: "TutunCoreTests", dependencies: ["TutunCore", "TutunShared"]),
        .testTarget(name: "TutunSystemTests", dependencies: ["TutunSystem"]),
        .testTarget(name: "TutunSharedTests", dependencies: ["TutunShared"]),
    ],
    swiftLanguageModes: [.v5]
)
