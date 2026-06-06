//
//  PosterBoardWallpaperManager.swift
//  lara
//

import Darwin
import Combine
import Dispatch
import Foundation
import UIKit

enum PosterBoardApplyError: LocalizedError {
    case darkSwordNotReady
    case systemNotInitialized
    case missingHash(String)
    case wrongHash
    case collectionsNeedReset
    case missingDescriptors
    case invalidTendies(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .darkSwordNotReady:
            return "DarkSword is not ready."
        case .systemNotInitialized:
            return "Initialize SBX or Hybrid system access before using PosterBoard wallpapers."
        case .missingHash(let name):
            return "Could not find the app hash for \(name)."
        case .wrongHash:
            return "The app hash is incorrect. Refresh hashes and try again."
        case .collectionsNeedReset:
            return "The target folder is not set up correctly. Reset PosterBoard collections and try again."
        case .missingDescriptors:
            return "No PosterBoard descriptors were found in this tendies file."
        case .invalidTendies(let message):
            return message
        case .unexpected(let message):
            return message
        }
    }
}

struct PosterBoardHashState {
    var posterBoard: String
    var carPlay: String
}

struct PosterBoardWallpaper: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var description: String?
    var authors: String?
    var preview: String
    var url: String
    var type: WallpaperType

    enum WallpaperType: String, Codable, CaseIterable, Hashable {
        case custom
        case apple
    }
}

struct PosterBoardCarPlayWallpaper: Identifiable {
    let id = UUID()
    var name: String
    var lightImage: UIImage
    var darkImage: UIImage
    var selectedLightData: Data?
    var selectedDarkData: Data?
}

final class PosterBoardWallpaperManager: ObservableObject {
    static let shared = PosterBoardWallpaperManager()

    static let posterBoardBundleID = "com.apple.PosterBoard"
    static let carPlayBundleID = "com.apple.CarPlayWallpaper"
    static let wallpapersURL = URL(string: "https://cowabun.ga/wallpapers")!
    static let maxTendies = 10

    @Published var selectedTendies: [URL] = []
    @Published var downloadableWallpapers: [PosterBoardWallpaper] = []
    @Published var downloadableStatus = "Loading..."

    private let fm = FileManager.default
    private var serverURL = ""
    private let mgr = laramgr.shared
    private let operationQueue = DispatchQueue(label: "lara.posterboard.operation")

    private init() {}

    func refreshHashes() throws -> PosterBoardHashState {
        guard mgr.dsready && ds_is_ready() else {
            throw PosterBoardApplyError.darkSwordNotReady
        }
        guard mgr.sbxready else {
            throw PosterBoardApplyError.systemNotInitialized
        }
        guard let hashes = mgr.PPHelperHashes() else {
            throw PosterBoardApplyError.unexpected("DarkSword could not enumerate app containers.")
        }

        var posterBoard = ""
        var carPlay = ""
        for hash in hashes {
            switch hash.bundleID {
            case Self.posterBoardBundleID:
                posterBoard = hash.value
            case Self.carPlayBundleID:
                carPlay = hash.value
            default:
                break
            }
        }

        guard !posterBoard.isEmpty else {
            throw PosterBoardApplyError.missingHash("PosterBoard")
        }

        mgr.logmsg("(posterboard) DarkSword found PosterBoard hash: \(posterBoard)")
        if !carPlay.isEmpty {
            mgr.logmsg("(posterboard) DarkSword found CarPlayWallpaper hash: \(carPlay)")
        }

        return PosterBoardHashState(posterBoard: posterBoard, carPlay: carPlay)
    }

    func documentsDirectory() -> URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func tendiesStoreURL() -> URL {
        let url = documentsDirectory().appendingPathComponent("PosterBoardTendies", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func carPlayPhotosURL() -> URL {
        let url = documentsDirectory().appendingPathComponent("CarPlayPhotos", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func importTendies(from url: URL) throws -> URL {
        guard url.pathExtension.lowercased() == "tendies" else {
            throw PosterBoardApplyError.unexpected("Only .tendies wallpaper files can be imported.")
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = tendiesStoreURL().appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: url, to: destination)
        return destination
    }

    func downloadWallpaper(_ wallpaper: PosterBoardWallpaper) async throws -> URL {
        guard let url = URL(string: wallpaper.url.hasPrefix("https://") ? wallpaper.url : serverURL + wallpaper.url) else {
            throw PosterBoardApplyError.unexpected("Invalid wallpaper download URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PosterBoardApplyError.unexpected("Could not download wallpaper.")
        }

        let destination = tendiesStoreURL().appendingPathComponent(url.lastPathComponent)
        guard destination.pathExtension.lowercased() == "tendies" else {
            throw PosterBoardApplyError.unexpected("The downloaded wallpaper is not a .tendies file.")
        }
        try? fm.removeItem(at: destination)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    func loadWallpaperIndex(type: PosterBoardWallpaper.WallpaperType, filter: PosterBoardWallpaperFilter) {
        downloadableStatus = "Loading..."
        Task {
            do {
                let base = try await resolveWallpaperServerURL()
                let listURL = URL(string: base + "wallpapers-\(type.rawValue).json")!
                let (data, response) = try await URLSession.shared.data(from: listURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw PosterBoardApplyError.unexpected("Could not fetch wallpaper index.")
                }
                var wallpapers = try JSONDecoder().decode([PosterBoardWallpaperIndexItem].self, from: data).map {
                    PosterBoardWallpaper(name: $0.name, description: $0.description, authors: $0.authors, preview: base + $0.preview, url: $0.url, type: type)
                }
                switch filter {
                case .random:
                    wallpapers.shuffle()
                case .newest:
                    wallpapers.reverse()
                case .oldest:
                    break
                }

                await MainActor.run {
                    self.downloadableWallpapers = wallpapers
                    self.downloadableStatus = wallpapers.isEmpty ? "No wallpapers found." : ""
                }
            } catch {
                await MainActor.run {
                    self.downloadableWallpapers = []
                    self.downloadableStatus = error.localizedDescription
                }
            }
        }
    }

    func applyPosterBoard(appHash: String, tendies: [URL]) throws {
        try performExclusiveOperation {
            try applyPosterBoardLocked(appHash: appHash, tendies: tendies)
        }
    }

    private func applyPosterBoardLocked(appHash: String, tendies: [URL]) throws {
        guard mgr.sbxready else {
            throw PosterBoardApplyError.systemNotInitialized
        }
        guard isValidAppHash(appHash) else {
            throw PosterBoardApplyError.missingHash("PosterBoard")
        }

        var extensionDescriptors: [String: [URL]] = [:]
        for tendie in tendies {
            let unzipped = try unzipTendies(at: tendie)
            guard let descriptors = try descriptorsFromTendies(unzipped) else {
                continue
            }
            extensionDescriptors.merge(descriptors) { $0 + $1 }
        }
        guard !extensionDescriptors.isEmpty else {
            throw PosterBoardApplyError.missingDescriptors
        }

        defer {
            cleanupSymlink()
            try? fm.removeItem(at: unzipRootURL())
            try? fm.removeItem(at: stagingRootURL())
        }

        for (providerExtension, descriptorRoots) in extensionDescriptors {
            guard isValidProviderExtension(providerExtension) else {
                throw PosterBoardApplyError.unexpected("Invalid PosterBoard provider extension in tendies file.")
            }
            _ = try createDescriptorsSymlink(appHash: appHash, providerExtension: providerExtension)
            for descriptorRoot in descriptorRoots {
                for descriptor in try fm.contentsOfDirectory(at: descriptorRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    guard descriptor.lastPathComponent != "__MACOSX" else { continue }
                    try validateDescriptor(descriptor)
                    try randomizeWallpaperIdentifier(in: descriptor)
                    let staged = try createStagingURL()
                    try fm.moveItem(at: descriptor, to: staged)
                    try fm.trashItem(at: staged, resultingItemURL: nil)
                }
            }
            cleanupSymlink()
        }
    }

    func clearPosterBoardScratch() throws {
        try performExclusiveOperation {
            guard mgr.sbxready else {
                throw PosterBoardApplyError.systemNotInitialized
            }
            cleanupSymlink()
            try? fm.removeItem(at: tendiesStoreURL())
            try? fm.removeItem(at: unzipRootURL())
            try? fm.removeItem(at: stagingRootURL())
        }
    }

    func resetPosterBoardCollections() throws -> Bool {
        try performExclusiveOperation {
            guard mgr.sbxready else {
                throw PosterBoardApplyError.systemNotInitialized
            }
            guard let language = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first else {
                throw PosterBoardApplyError.unexpected("Could not read the active system language.")
            }
            return setSystemLanguage(to: language)
        }
    }

    func openPosterBoard() -> Bool {
        guard let workspaceClass = objc_getClass("LSApplicationWorkspace") as? NSObject else {
            return false
        }
        let workspace = workspaceClass.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() as? NSObject
        let result = workspace?.perform(Selector(("openApplicationWithBundleID:")), with: Self.posterBoardBundleID)
        return result != nil
    }

    func setSystemLanguage(to language: String) -> Bool {
        let className = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18 ? "IPSettingsUtilities" : "PSLanguageSelector"
        guard let languageClass = objc_getClass(className) as? NSObject else {
            return false
        }
        return languageClass.perform(Selector(("setLanguage:")), with: language) != nil
    }

    func supportsCarPlay() -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return false
        }

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 19 {
            var buildBuffer = [CChar](repeating: 0, count: 16)
            var buildBufferLength = size_t(buildBuffer.count - 1)
            let result = sysctlbyname("kern.osversion", &buildBuffer, &buildBufferLength, nil, 0)
            guard result == 0, let build = String(validatingUTF8: buildBuffer) else {
                return false
            }

            return build == "23A5260n"
                || build == "23A5260u"
                || build == "23A5276f"
                || build == "23A5287g"
        }

        return true
    }

    func carPlayCacheVersion() -> String {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 19 {
            return "-12"
        }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18 {
            return "-11"
        }
        return ""
    }

    func loadCarPlayWallpapers() throws -> [PosterBoardCarPlayWallpaper] {
        let frameworkURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CarPlayUIServices.framework", isDirectory: true)
        let photosURL = carPlayPhotosURL()
        let files = try fm.contentsOfDirectory(at: frameworkURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var wallpapers: [PosterBoardCarPlayWallpaper] = []

        for file in files where file.lastPathComponent.hasSuffix("-Light.heic") {
            let lightData = try Data(contentsOf: file)
            guard let lightImage = UIImage(data: lightData) else { continue }

            let name = file.lastPathComponent.replacingOccurrences(of: "-Light.heic", with: "")
            let darkURL = URL(fileURLWithPath: file.path.replacingOccurrences(of: "-Light.heic", with: "-Dark.heic"))
            let darkImage = (try? Data(contentsOf: darkURL)).flatMap(UIImage.init(data:)) ?? lightImage
            let selectedLight = try? Data(contentsOf: photosURL.appendingPathComponent("\(name)-Light"))
            let selectedDark = try? Data(contentsOf: photosURL.appendingPathComponent("\(name)-Dark"))

            wallpapers.append(PosterBoardCarPlayWallpaper(
                name: name,
                lightImage: lightImage,
                darkImage: darkImage,
                selectedLightData: selectedLight,
                selectedDarkData: selectedDark
            ))
        }

        if let order = carPlayWallpaperOrder() {
            wallpapers.sort { left, right in
                let leftIndex = order.firstIndex(of: left.name) ?? Int.max
                let rightIndex = order.firstIndex(of: right.name) ?? Int.max
                return leftIndex == rightIndex ? left.name < right.name : leftIndex < rightIndex
            }
        }

        return wallpapers
    }

    func applyCarPlay(appHash: String, wallpapers: [PosterBoardCarPlayWallpaper]) throws -> [String] {
        try performExclusiveOperation {
            try applyCarPlayLocked(appHash: appHash, wallpapers: wallpapers)
        }
    }

    private func applyCarPlayLocked(appHash: String, wallpapers: [PosterBoardCarPlayWallpaper]) throws -> [String] {
        guard mgr.sbxready else {
            throw PosterBoardApplyError.systemNotInitialized
        }
        guard isValidAppHash(appHash) else {
            throw PosterBoardApplyError.missingHash("CarPlayWallpaper")
        }

        var active = UserDefaults.standard.array(forKey: "PosterBoardActiveCarPlayWallpapers") as? [String] ?? []
        var stagedImages: [URL] = []
        let photosURL = carPlayPhotosURL()
        let cacheVersion = carPlayCacheVersion()

        for wallpaper in wallpapers {
            if let data = wallpaper.selectedLightData, let image = UIImage(data: data) {
                let url = documentsDirectory().appendingPathComponent("CAR\(wallpaper.name)Dynamic-Light\(cacheVersion).cpbitmap")
                try image.writePosterBoardCPBitmap(to: url)
                try? data.write(to: photosURL.appendingPathComponent("\(wallpaper.name)-Light"))
                stagedImages.append(url)
                if !active.contains(wallpaper.name) {
                    active.append(wallpaper.name)
                }
            }
            if let data = wallpaper.selectedDarkData, let image = UIImage(data: data) {
                let url = documentsDirectory().appendingPathComponent("CAR\(wallpaper.name)Dynamic-Dark\(cacheVersion).cpbitmap")
                try image.writePosterBoardCPBitmap(to: url)
                try? data.write(to: photosURL.appendingPathComponent("\(wallpaper.name)-Dark"))
                stagedImages.append(url)
                if !active.contains(wallpaper.name) {
                    active.append(wallpaper.name)
                }
            }
        }

        defer {
            cleanupSymlink()
        }

        _ = try createAppSymlink(for: "\(appHash)/Library/Caches/MappedImageCache/com.apple.CarPlayApp.wallpaper-images")
        for image in stagedImages {
            try fm.trashItem(at: image, resultingItemURL: nil)
        }
        try Data().write(to: documentsDirectory().appendingPathComponent("Caches"))

        UserDefaults.standard.set(active, forKey: "PosterBoardActiveCarPlayWallpapers")
        return active
    }

    private func resolveWallpaperServerURL() async throws -> String {
        if !serverURL.isEmpty {
            return serverURL
        }

        let url = URL(string: "https://api.github.com/repos/SerStars/nugget-wallpapers/commits/main")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = info["sha"] as? String else {
            throw PosterBoardApplyError.unexpected("Unable to obtain wallpaper repo hash.")
        }

        let resolved = "https://raw.githubusercontent.com/SerStars/nugget-wallpapers/\(hash)/"
        serverURL = resolved
        return resolved
    }

    private func unzipTendies(at source: URL) throws -> URL {
        let root = unzipRootURL()
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let archive = try ZipArchive(data: try Data(contentsOf: source))
        for entry in archive.entries {
            guard let normalized = safeZipPath(entry.path) else { continue }
            let output = destination.appendingPathComponent(normalized, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extract(entry).write(to: output)
            }
        }

        return destination
    }

    private func descriptorsFromTendies(_ url: URL) throws -> [String: [URL]]? {
        for item in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            switch item.lastPathComponent.lowercased() {
            case "container":
                let extensionsDir = item.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore/61/Extensions")
                var result: [String: [URL]] = [:]
                for providerExtension in try fm.contentsOfDirectory(at: extensionsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    let descriptors = providerExtension.appendingPathComponent("descriptors", isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: descriptors.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        continue
                    }
                    result[providerExtension.lastPathComponent] = [descriptors]
                }
                return result.isEmpty ? nil : result
            case "descriptor", "descriptors", "ordered-descriptor", "ordered-descriptors":
                return ["com.apple.WallpaperKit.CollectionsPoster": [item]]
            case "video-descriptor", "video-descriptors":
                return ["com.apple.PhotosUIPrivate.PhotosPosterProvider": [item]]
            default:
                continue
            }
        }
        return nil
    }

    private func randomizeWallpaperIdentifier(in url: URL) throws {
        let randomizedID = Int.random(in: 9999...99999)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            switch fileURL.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try String(randomizedID).data(using: .utf8)?.write(to: fileURL)
            case "com.apple.posterkit.provider.contents.userInfo":
                try setPlistValue(fileURL, key: "wallpaperRepresentingIdentifier", value: randomizedID)
            case "Wallpaper.plist":
                try setPlistValue(fileURL, key: "identifier", value: randomizedID)
            default:
                continue
            }
        }
    }

    private func validateDescriptor(_ descriptor: URL) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: descriptor.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PosterBoardApplyError.invalidTendies("A PosterBoard descriptor is not a directory.")
        }

        let identifierURL = descriptor.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        guard let identifier = try? String(contentsOf: identifierURL).trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            throw PosterBoardApplyError.invalidTendies("A PosterBoard descriptor is missing its provider identifier.")
        }

        let contentsURL = descriptor.appendingPathComponent("versions/1/contents", isDirectory: true)
        guard fm.fileExists(atPath: contentsURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PosterBoardApplyError.invalidTendies("A PosterBoard descriptor is missing versioned contents.")
        }

        let userInfoURL = contentsURL.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
        let userInfo = try propertyListDictionary(at: userInfoURL)
        guard userInfo["wallpaperRepresentingIdentifier"] != nil else {
            throw PosterBoardApplyError.invalidTendies("A PosterBoard descriptor has invalid provider user info.")
        }

        var foundWallpaperPlist = false
        guard let enumerator = fm.enumerator(at: descriptor, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw PosterBoardApplyError.invalidTendies("A PosterBoard descriptor could not be inspected.")
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            switch fileURL.lastPathComponent {
            case "Wallpaper.plist":
                let plist = try propertyListDictionary(at: fileURL)
                guard plist["identifier"] != nil else {
                    throw PosterBoardApplyError.invalidTendies("A PosterBoard wallpaper plist is missing its identifier.")
                }
                foundWallpaperPlist = true
            case _ where fileURL.pathExtension.lowercased() == "plist":
                _ = try propertyListDictionary(at: fileURL)
            case _ where fileURL.pathExtension.lowercased() == "xml" || fileURL.pathExtension.lowercased() == "caml":
                try validateXML(at: fileURL)
            default:
                continue
            }
        }

        guard foundWallpaperPlist else {
            throw PosterBoardApplyError.invalidTendies("A PosterBoard descriptor does not contain a wallpaper plist.")
        }
    }

    private func propertyListDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PosterBoardApplyError.invalidTendies("\(url.lastPathComponent) is not a valid property list.")
        }
        return plist
    }

    private func validateXML(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw PosterBoardApplyError.invalidTendies("\(url.lastPathComponent) is empty.")
        }
        let parser = XMLParser(data: data)
        guard parser.parse() else {
            throw PosterBoardApplyError.invalidTendies("\(url.lastPathComponent) is not valid XML.")
        }
    }

    private func setPlistValue(_ url: URL, key: String, value: Any) throws {
        guard let data = try? Data(contentsOf: url),
              var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              PropertyListSerialization.propertyList(plist, isValidFor: .xml) else {
            throw PosterBoardApplyError.unexpected("Could not update \(url.lastPathComponent).")
        }

        plist[key] = value
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: url, options: [.atomic])
    }

    private func createDescriptorsSymlink(appHash: String, providerExtension: String) throws -> URL {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17 ? "61" : "59"
        return try createAppSymlink(for: "\(appHash)/Library/Application Support/PRBPosterExtensionDataStore/\(version)/Extensions/\(providerExtension)/descriptors")
    }

    private func createAppSymlink(for appHash: String) throws -> URL {
        let relativeComponents = appHash.split(separator: "/", omittingEmptySubsequences: false)
        guard let hash = relativeComponents.first.map(String.init), isValidAppHash(hash) else {
            throw PosterBoardApplyError.wrongHash
        }

        let containerPath = "/var/mobile/Containers/Data/Application/\(hash)"
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: containerPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PosterBoardApplyError.wrongHash
        }

        let fullPath = "/var/mobile/Containers/Data/Application/\(appHash)"
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PosterBoardApplyError.collectionsNeedReset
        }

        return try createSymlink(to: fullPath)
    }

    private func createSymlink(to path: String) throws -> URL {
        let url = documentsDirectory().appendingPathComponent(".Trash")
        cleanupSymlink()
        try fm.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: path, isDirectory: true))
        return url
    }

    private func cleanupSymlink() {
        try? fm.removeItem(at: documentsDirectory().appendingPathComponent(".Trash"))
    }

    private func unzipRootURL() -> URL {
        documentsDirectory().appendingPathComponent("PosterBoardUnzip", isDirectory: true)
    }

    private func stagingRootURL() -> URL {
        documentsDirectory().appendingPathComponent("PosterBoardStaging", isDirectory: true)
    }

    private func createStagingURL() throws -> URL {
        let root = stagingRootURL()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func safeZipPath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private func isValidAppHash(_ hash: String) -> Bool {
        UUID(uuidString: hash) != nil
    }

    private func isValidProviderExtension(_ providerExtension: String) -> Bool {
        guard !providerExtension.isEmpty,
              !providerExtension.contains("/"),
              !providerExtension.contains("\\"),
              !providerExtension.contains("..") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        return providerExtension.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func performExclusiveOperation<T>(_ operation: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        operationQueue.sync {
            result = Result {
                try operation()
            }
        }
        return try result.get()
    }

    private func carPlayWallpaperOrder() -> [String]? {
        dlopen("/System/Library/PrivateFrameworks/CarPlayUIServices.framework/CarPlayUIServices", RTLD_GLOBAL)

        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVersion >= 18 {
            guard let wallpaperClass = objc_getClass("CRSUISystemWallpaper") as? NSObject,
                  let result = wallpaperClass.perform(Selector(("wallpapers")))?.takeUnretainedValue() as? [NSObject] else {
                return nil
            }
            return result.compactMap {
                $0.perform(Selector(("wallpaperAssetCatalogName")))?.takeUnretainedValue() as? String
            }
        }

        guard let preferencesClass = objc_getClass("CRSUIWallpaperPreferences") as? NSObject,
              let result = preferencesClass.perform(Selector(("availableWallpapers")))?.takeUnretainedValue() as? [NSObject] else {
            return nil
        }
        return result.compactMap {
            $0.perform(Selector(("wallpaperAssetCatalogName")))?.takeUnretainedValue() as? String
        }
    }
}

enum PosterBoardWallpaperFilter: String, CaseIterable, Hashable {
    case random = "Random"
    case newest = "Newest"
    case oldest = "Oldest"
}

private struct PosterBoardWallpaperIndexItem: Decodable {
    let name: String
    let description: String?
    let url: String
    let preview: String
    let authors: String?
}

private extension UIImage {
    func writePosterBoardCPBitmap(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var error: NSError?
        guard lara_write_cpbitmap(self, url.path, &error) else {
            throw error ?? PosterBoardApplyError.unexpected("UIImage cannot write cpbitmap files on this OS.")
        }
    }
}
