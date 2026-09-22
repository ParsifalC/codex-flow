import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

private let petMaxResourceBytes = 16 * 1024 * 1024
private let petMaxPixels = 16 * 1024 * 1024

private struct PetMetadata: Decodable {
    let id: String
    let displayName: String
    let description: String
    let spriteVersionNumber: Int
    let spritesheetPath: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case description
        case spriteVersionNumber
        case spritesheetPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        spriteVersionNumber = try container.decodeIfPresent(Int.self, forKey: .spriteVersionNumber) ?? 1
        spritesheetPath = try container.decode(String.self, forKey: .spritesheetPath)
    }
}

public final class PetAtlas {
    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    public let frameSize: CGSize

    private let sourceImage: CGImage
    private final class CachedImage: NSObject {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }
    private let frameCache = NSCache<NSString, CachedImage>()

    public init(url: URL, spriteVersionNumber: Int) throws {
        guard spriteVersionNumber == 1 || spriteVersionNumber == 2 else {
            throw PetResourceError.invalidMetadata("spriteVersionNumber must be 1 or 2")
        }
        guard !PetPathSafety.isSymlink(url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= petMaxResourceBytes else {
            throw PetResourceError.invalidResource("spritesheet exceeds the size limit or is a symlink")
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let propertyWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let propertyHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw PetResourceError.invalidResource("spritesheet could not be decoded")
        }
        let width = propertyWidth.intValue
        let height = propertyHeight.intValue
        guard width > 0, height > 0,
              width <= petMaxPixels,
              height <= petMaxPixels,
              width <= petMaxPixels / height else {
            throw PetResourceError.invalidResource("spritesheet dimensions exceed the limit")
        }
        let expectedRows = spriteVersionNumber == 2 ? 11 : 9
        guard width % 8 == 0, height % expectedRows == 0 else {
            throw PetResourceError.invalidResource("spritesheet dimensions are not an 8x\(expectedRows) atlas")
        }

        guard let type = CGImageSourceGetType(source),
              let identifier = type as String?,
              identifier == UTType.png.identifier || identifier == "org.webmproject.webp" else {
            throw PetResourceError.invalidResource("spritesheet must be PNG or WebP")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetResourceError.invalidResource("spritesheet could not be decoded")
        }

        self.width = width
        self.height = height
        self.columns = 8
        self.rows = expectedRows
        self.frameSize = CGSize(width: width / 8, height: height / expectedRows)
        self.sourceImage = image
        frameCache.countLimit = 48
        frameCache.totalCostLimit = 32 * 1024 * 1024
    }

    public var frameCacheCountLimit: Int { frameCache.countLimit }

    public func frameImage(for state: PetState, frame: Int) -> CGImage? {
        let definition = PetAnimationTable.definition(for: state)
        guard definition.row < rows,
              frame >= 0,
              frame < definition.frames.count else { return nil }
        let column = definition.frames[frame].column
        guard column >= 0, column < columns else { return nil }
        let key = "\(state.rawValue):\(frame)" as NSString
        if let cached = frameCache.object(forKey: key) {
            return cached.image
        }
        let crop = CGRect(
            x: column * Int(frameSize.width),
            y: definition.row * Int(frameSize.height),
            width: Int(frameSize.width),
            height: Int(frameSize.height)
        )
        guard let image = sourceImage.cropping(to: crop) else { return nil }
        frameCache.setObject(CachedImage(image), forKey: key, cost: image.width * image.height * 4)
        return image
    }
}

public struct PetResource {
    public let id: String
    public let displayName: String
    public let description: String
    public let spriteVersionNumber: Int
    public let atlas: PetAtlas

    public init(id: String, displayName: String, description: String, spriteVersionNumber: Int, atlas: PetAtlas) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spriteVersionNumber = spriteVersionNumber
        self.atlas = atlas
    }
}

public enum PetResourceLoadResult {
    case builtIn
    case loaded(PetResource)
    case rejected(String)
}

public enum PetResourceError: LocalizedError {
    case invalidSelection(String)
    case invalidMetadata(String)
    case invalidResource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSelection(let message), .invalidMetadata(let message), .invalidResource(let message):
            return message
        }
    }
}

public final class PetResourceStore {
    public let codexHome: URL
    public private(set) var currentResource: PetResource?
    public private(set) var lastSelectionID: String = "default"

    // Settings can render five choices at once. Keep the first idle frame in
    // a process-wide cache so SwiftUI body recomputation does not decode the
    // full atlas again for every row. The atlas itself remains private to the
    // validated resource loader below.
    private final class CachedThumbnail: NSObject {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private static let thumbnailCache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.countLimit = 48
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    public init(codexHome: URL? = nil) {
        if let codexHome {
            self.codexHome = codexHome
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
        }
    }

    @discardableResult
    public func reload() -> PetResourceLoadResult {
        do {
            let selection = try readSelection()
            lastSelectionID = selection
            guard selection != "default" else {
                currentResource = nil
                return .builtIn
            }
            let package = try loadPackage(id: selection)
            currentResource = package
            return .loaded(package)
        } catch {
            currentResource = nil
            return .rejected(error.localizedDescription)
        }
    }

    /// Return the validated idle frame used by the settings picker.
    ///
    /// The package path is resolved from the managed installed directory and
    /// never from UI supplied metadata. This keeps previews subject to the
    /// same path, symlink, metadata, and atlas checks as the active resource.
    public func thumbnail(for id: String) throws -> CGImage? {
        guard id != "default" else { return nil }
        let packageURL = petRoot.appendingPathComponent("installed").appendingPathComponent(id)
        let metadataURL = packageURL.appendingPathComponent("pet.json")
        let timestamp = (try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(codexHome.standardizedFileURL.path):\(id):\(timestamp)" as NSString
        if let cached = Self.thumbnailCache.object(forKey: key) {
            return cached.image
        }
        let resource = try loadPackage(id: id)
        guard let image = resource.atlas.frameImage(for: .idle, frame: 0) else {
            return nil
        }
        // A cropped CGImage may retain its full atlas backing. Draw into a
        // small independent bitmap before caching so the memory cost is real.
        let scale = min(1.0, 208.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        Self.thumbnailCache.setObject(CachedThumbnail(thumbnail), forKey: key, cost: width * height * 4)
        return thumbnail
    }

    private var petRoot: URL {
        codexHome.appendingPathComponent("codex-flow", isDirectory: true).appendingPathComponent("pets", isDirectory: true)
    }

    private func readSelection() throws -> String {
        let current = petRoot.appendingPathComponent("current")
        guard FileManager.default.fileExists(atPath: current.path) else { return "default" }
        guard !PetPathSafety.isSymlink(current) else {
            throw PetResourceError.invalidSelection("pets/current may not be a symlink")
        }
        let data = try Data(contentsOf: current)
        guard data.count <= 4096 else {
            throw PetResourceError.invalidSelection("pets/current exceeds the selection size limit")
        }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "default"
        }
        guard value == "default" || PetPathSafety.isSafeID(value) else {
            throw PetResourceError.invalidSelection("pet selection contains an unsafe path component")
        }
        return value
    }

    private func loadPackage(id: String) throws -> PetResource {
        let installed = petRoot.appendingPathComponent("installed", isDirectory: true)
        let packageURL = installed.appendingPathComponent(id, isDirectory: true)
        guard PetPathSafety.isWithin(packageURL, root: installed),
              !PetPathSafety.containsSymlink(from: installed, to: packageURL),
              FileManager.default.fileExists(atPath: packageURL.path) else {
            throw PetResourceError.invalidResource("selected pet package is missing or unsafe")
        }

        let metadataURL = packageURL.appendingPathComponent("pet.json")
        guard !PetPathSafety.isSymlink(metadataURL) else {
            throw PetResourceError.invalidResource("pet.json may not be a symlink")
        }
        guard let metadataValues = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]),
              let metadataSize = metadataValues.fileSize,
              metadataSize <= 256 * 1024 else {
            throw PetResourceError.invalidMetadata("pet.json exceeds the size limit")
        }
        let metadataData = try Data(contentsOf: metadataURL)
        guard metadataData.count <= 256 * 1024 else {
            throw PetResourceError.invalidMetadata("pet.json exceeds the size limit")
        }
        let metadata = try JSONDecoder().decode(PetMetadata.self, from: metadataData)
        guard metadata.id == id, !metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PetResourceError.invalidMetadata("pet.json id/displayName does not match the selected package")
        }
        guard metadata.spritesheetPath.hasSuffix(".png") || metadata.spritesheetPath.hasSuffix(".webp"),
              !metadata.spritesheetPath.hasPrefix("/"),
              PetPathSafety.isSafeRelativePath(metadata.spritesheetPath) else {
            throw PetResourceError.invalidMetadata("spritesheetPath must stay inside the package")
        }
        let spriteURL = packageURL.appendingPathComponent(metadata.spritesheetPath)
        guard PetPathSafety.isWithin(spriteURL, root: packageURL),
              !PetPathSafety.containsSymlink(from: packageURL, to: spriteURL),
              FileManager.default.fileExists(atPath: spriteURL.path) else {
            throw PetResourceError.invalidResource("spritesheet is missing or unsafe")
        }
        let atlas = try PetAtlas(url: spriteURL, spriteVersionNumber: metadata.spriteVersionNumber)
        return PetResource(
            id: metadata.id,
            displayName: metadata.displayName,
            description: metadata.description,
            spriteVersionNumber: metadata.spriteVersionNumber,
            atlas: atlas
        )
    }
}

private enum PetPathSafety {
    static func isSafeID(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value != "default", value != "current", value != "installed" else {
            return value == "default"
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("\\"), !value.contains("\0"), !value.hasPrefix("/") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    static func isWithin(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = candidate.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func containsSymlink(from root: URL, to descendant: URL) -> Bool {
        guard isWithin(descendant, root: root) else { return true }
        var current = descendant.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while current.path != rootPath {
            if isSymlink(current) { return true }
            current.deleteLastPathComponent()
        }
        return isSymlink(root)
    }
}
