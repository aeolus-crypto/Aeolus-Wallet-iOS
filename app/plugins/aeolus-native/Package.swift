// swift-tools-version: 5.9
import PackageDescription

// ios/Frameworks/ZephyrIOS.xcframework is the wallet engine built by zephyr-engine/ (CI puts it
// there before building the app; it is not in git).
let package = Package(
    name: "AeolusNative",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "AeolusNative", targets: ["AeolusNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .binaryTarget(name: "ZephyrIOS", path: "ios/Frameworks/ZephyrIOS.xcframework"),
        .target(
            name: "AeolusNative",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                "ZephyrIOS"
            ],
            path: "ios/Sources/AeolusNative",
            resources: [.copy("Resources/cacert.pem")],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("MessageUI"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
