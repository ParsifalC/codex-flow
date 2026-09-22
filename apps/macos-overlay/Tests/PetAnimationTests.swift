import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct PetAnimationTests {
    static func main() throws {
        testAnimationTableAndReducer()
        testAnimatorVisibilityAndReducedMotion()
        try testFrameCropUsesTopOrigin()
        try testResourceLoadingAndFallback()
        print("Pet animation, resource decoding, fallback and interaction tests passed")
    }

    private static func testAnimationTableAndReducer() {
        let expected: [(PetState, Int, [Int])] = [
            (.idle, 0, [280, 110, 110, 140, 140, 320]),
            (.runningRight, 1, Array(repeating: 120, count: 7) + [220]),
            (.runningLeft, 2, Array(repeating: 120, count: 7) + [220]),
            (.waving, 3, [140, 140, 140, 280]),
            (.jumping, 4, [140, 140, 140, 140, 280]),
            (.failed, 5, Array(repeating: 140, count: 7) + [240]),
            (.waiting, 6, [150, 150, 150, 150, 150, 260]),
            (.running, 7, [120, 120, 120, 120, 120, 220]),
            (.review, 8, [150, 150, 150, 150, 150, 280])
        ]

        precondition(PetState.allCases.count == expected.count, "PetState must expose exactly nine rows")
        for (state, row, durations) in expected {
            let definition = PetAnimationTable.definition(for: state)
            precondition(definition.row == row, "Unexpected row for \(state.rawValue)")
            precondition(definition.frames.map(\.durationMilliseconds) == durations, "Unexpected durations for \(state.rawValue)")
            precondition(definition.frames.map(\.column) == Array(0..<durations.count), "Unexpected frame columns for \(state.rawValue)")
        }

        var reducer = PetAnimationReducer()
        precondition(reducer.state == .idle && reducer.frameIndex == 0)
        reducer.setTaskState(.running)
        reducer.playTransient(.waving)
        precondition(reducer.state == .waving && reducer.frameIndex == 0)
        reducer.advance(by: 140 + 140 + 140 + 280)
        precondition(reducer.state == .running && reducer.frameIndex == 0, "Waving must return to the task state")

        reducer.beginDrag(direction: .left)
        precondition(reducer.state == .runningLeft)
        reducer.setTaskState(.review)
        precondition(reducer.state == .runningLeft, "Task events must not cover an active directional drag")
        reducer.endDrag()
        precondition(reducer.state == .review)

        reducer.setTaskState(.waiting)
        reducer.playTransient(.waving)
        precondition(reducer.state == .waiting, "Hover cannot cover waiting")
        reducer.setTaskState(.failed)
        reducer.advance(by: 7 * 140 + 240)
        precondition(reducer.state == .failed && reducer.frameIndex == 7, "Failed must hold its terminal frame")
        reducer.clear()
        precondition(reducer.state == .idle && reducer.frameIndex == 0)
    }

    private static func testAnimatorVisibilityAndReducedMotion() {
        let animator = PetAnimator()
        animator.setVisibility(visible: true, expanded: false, reduceMotion: true)
        precondition(!animator.timerIsRunning, "Reduced motion must not schedule a timer")
        animator.setTaskState(.running)
        animator.advance(by: 300)
        animator.setVisibility(visible: true, expanded: false, reduceMotion: true)
        precondition(animator.frameIndex == 0, "Reduced motion must keep a static first frame")
        animator.setVisibility(visible: true, expanded: false, reduceMotion: false)
        precondition(animator.timerIsRunning, "A visible compact pet should animate")
        animator.setVisibility(visible: true, expanded: true, reduceMotion: false)
        precondition(!animator.timerIsRunning, "Expanded overlay must stop the animation timer")
        animator.setVisibility(visible: false, expanded: false, reduceMotion: false)
        precondition(!animator.timerIsRunning, "Hidden pet must stop the animation timer")
        animator.stop()
    }

    private static func testFrameCropUsesTopOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-crop-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cellWidth = 12
        let cellHeight = 13
        let width = cellWidth * 8
        let height = cellHeight * 11
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<11 {
            for column in 0..<8 {
                let marker = (UInt8(row + 1), UInt8(column + 1), UInt8(200 - row))
                for y in 0..<cellHeight {
                    for x in 0..<cellWidth {
                        let offset = ((row * cellHeight + y) * width + column * cellWidth + x) * 4
                        pixels[offset] = marker.0
                        pixels[offset + 1] = marker.1
                        pixels[offset + 2] = marker.2
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            preconditionFailure("Unable to build crop marker image")
        }
        let atlasURL = root.appendingPathComponent("markers.png")
        guard let destination = CGImageDestinationCreateWithURL(
            atlasURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            preconditionFailure("Unable to create crop marker PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "Unable to write crop marker PNG")

        let atlas = try PetAtlas(url: atlasURL, spriteVersionNumber: 2)
        for state in PetState.allCases {
            let definition = PetAnimationTable.definition(for: state)
            for (frameIndex, frame) in definition.frames.enumerated() {
                guard let cropped = atlas.frameImage(for: state, frame: frameIndex),
                      let data = cropped.dataProvider?.data,
                      let bytes = CFDataGetBytePtr(data) else {
                    preconditionFailure("Missing crop for (state.rawValue) frame (frameIndex)")
                }
                let offset = cropped.bytesPerRow + 4
                let actual = (bytes[offset], bytes[offset + 1], bytes[offset + 2])
                let expected = (UInt8(definition.row + 1), UInt8(frame.column + 1), UInt8(200 - definition.row))
                precondition(actual.0 == expected.0 && actual.1 == expected.1 && actual.2 == expected.2,
                             "Crop marker mismatch for (state.rawValue) frame (frameIndex): (actual) != (expected)")
            }
        }
    }

    private static func testResourceLoadingAndFallback() throws {
        let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PET_FIXTURES_ROOT"] ?? "")
        precondition(FileManager.default.fileExists(atPath: fixtureRoot.path), "Pet fixtures are missing")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-native-\(UUID().uuidString)")
        let home = root.appendingPathComponent("codex-home")
        let installed = home.appendingPathComponent("codex-flow/pets/installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["synthetic-v1", "synthetic-v2", "synthetic-v2-webp"] {
            try FileManager.default.copyItem(
                at: fixtureRoot.appendingPathComponent(name),
                to: installed.appendingPathComponent(name)
            )
        }

        let pngId = "synthetic-v2"
        try Data(pngId.utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
        let store = PetResourceStore(codexHome: home)
        guard case let .loaded(png) = store.reload() else {
            preconditionFailure("Synthetic PNG package should load")
        }
        precondition(png.atlas.columns == 8 && png.atlas.rows == 11)
        precondition(png.atlas.frameSize == CGSize(width: 12, height: 13))
        precondition(png.atlas.frameCacheCountLimit == 48)
        let thumbnail = try store.thumbnail(for: pngId)!
        precondition(thumbnail.width <= 208 && thumbnail.height <= 208)
        let thumbnailBytes = thumbnail.dataProvider!.data!
        precondition(CFDataGetLength(thumbnailBytes) == thumbnail.width * thumbnail.height * 4,
                     "Thumbnail must own only its small bitmap, not retain the full atlas")
        precondition(png.atlas.frameImage(for: .review, frame: 0)?.width == 12)
        precondition(png.atlas.frameImage(for: .review, frame: 0)?.height == 13)

        try Data("synthetic-v2-webp".utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
        guard case let .loaded(webp) = store.reload() else {
            preconditionFailure("Synthetic WebP package should load")
        }
        precondition(webp.atlas.frameSize == CGSize(width: 12, height: 13))
        precondition(webp.atlas.frameImage(for: .idle, frame: 0) != nil)

        try Data("synthetic-v1".utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
        guard case let .loaded(v1) = store.reload() else {
            preconditionFailure("Synthetic v1 package should load")
        }
        precondition(v1.atlas.columns == 8 && v1.atlas.rows == 9)
        precondition(v1.atlas.frameSize == CGSize(width: 12, height: 13))

        if let configuredBobaPath = ProcessInfo.processInfo.environment["PET_REAL_RESOURCE_PATH"],
           !configuredBobaPath.isEmpty {
            let bobaSource = URL(fileURLWithPath: configuredBobaPath)
            guard FileManager.default.fileExists(atPath: bobaSource.appendingPathComponent("pet.json").path),
                  FileManager.default.fileExists(atPath: bobaSource.appendingPathComponent("spritesheet.webp").path) else {
                preconditionFailure("PET_REAL_RESOURCE_PATH must point to a Boba package")
            }
            let boba = installed.appendingPathComponent("boba")
            try FileManager.default.copyItem(at: bobaSource, to: boba)
            try Data("boba".utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
            guard case let .loaded(realBoba) = store.reload() else {
                preconditionFailure("The available Boba WebP should decode with ImageIO")
            }
            precondition(realBoba.atlas.frameSize == CGSize(width: 192, height: 208))
            precondition(realBoba.atlas.frameImage(for: .review, frame: 0)?.width == 192)
            print("Real Boba WebP decoded at 1536x2288")
        }

        try Data("default".utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
        guard case .builtIn = store.reload() else {
            preconditionFailure("Default selection should use the built-in appearance")
        }

        try Data("../synthetic-v2".utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
        guard case .rejected = store.reload() else {
            preconditionFailure("Path traversal selection should be rejected")
        }

        try? FileManager.default.removeItem(at: installed.appendingPathComponent("synthetic-v2"))
        try FileManager.default.createSymbolicLink(
            at: installed.appendingPathComponent("synthetic-v2"),
            withDestinationURL: installed.appendingPathComponent("synthetic-v2-webp")
        )
        try Data("synthetic-v2".utf8).write(to: home.appendingPathComponent("codex-flow/pets/current"))
        guard case .rejected = store.reload() else {
            preconditionFailure("Symlinked package paths should be rejected")
        }
    }
}
