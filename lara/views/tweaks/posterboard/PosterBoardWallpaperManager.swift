//
//  PosterBoardWallpaperManager.swift
//  lara
//

import Darwin
import Combine
import Foundation
import UIKit

enum PosterBoardApplyError: LocalizedError {
    case darkSwordNotReady
    case missingHash(String)
    case wrongHash
    case collectionsNeedReset
    case missingDescriptors
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .darkSwordNotReady:
            return "DarkSword is not ready."
        case .missingHash(let name):
            return "Could not find the app hash for \(name)."
        case .wrongHash:
            return "The app hash is incorrect. Refresh hashes and try again."
        case .collectionsNeedReset:
            return "The target folder is not set up correctly. Reset PosterBoard collections and try again."
        case .missingDescriptors:
            return "No PosterBoard descriptors were found in this tendies file."
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

    private init() {}

    func refreshHashes() throws -> PosterBoardHashState {
        guard mgr.dsready && ds_is_ready() else {
            throw PosterBoardApplyError.darkSwordNotReady
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
        try? fm.removeItem(at: destination)
        try data.write(to: destination)
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
        guard !appHash.isEmpty else {
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
            try? fm.removeItem(at: documentsDirectory().appendingPathComponent("PosterBoardUnzip", isDirectory: true))
        }

        for (providerExtension, descriptorRoots) in extensionDescriptors {
            _ = try createDescriptorsSymlink(appHash: appHash, providerExtension: providerExtension)
            for descriptorRoot in descriptorRoots {
                for descriptor in try fm.contentsOfDirectory(at: descriptorRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    guard descriptor.lastPathComponent != "__MACOSX" else { continue }
                    try randomizeWallpaperIdentifier(in: descriptor)
                    let staged = documentsDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fm.moveItem(at: descriptor, to: staged)
                    try fm.trashItem(at: staged, resultingItemURL: nil)
                }
            }
            cleanupSymlink()
        }
    }

    func clearPosterBoardCache() throws {
        cleanupSymlink()
        for file in try fm.contentsOfDirectory(at: documentsDirectory(), includingPropertiesForKeys: nil) {
            if file.lastPathComponent != "CarPlayPhotos" {
                try? fm.removeItem(at: file)
            }
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
        UIDevice.current.userInterfaceIdiom == .phone
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
        guard !appHash.isEmpty else {
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
        let root = documentsDirectory().appendingPathComponent("PosterBoardUnzip", isDirectory: true)
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let archive = try ZipArchive(data: try Data(contentsOf: source))
        for entry in archive.entries {
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard !normalized.contains("..") else { continue }

            let output = destination.appendingPathComponent(normalized)
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
                    result[providerExtension.lastPathComponent] = [providerExtension.appendingPathComponent("descriptors")]
                }
                return result
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
                setPlistValue(fileURL, key: "wallpaperRepresentingIdentifier", value: randomizedID)
            case "Wallpaper.plist":
                setPlistValue(fileURL, key: "identifier", value: randomizedID)
            default:
                continue
            }
        }
    }

    private func setPlistValue(_ url: URL, key: String, value: Any) {
        guard let data = try? Data(contentsOf: url),
              var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              PropertyListSerialization.propertyList(plist, isValidFor: .xml) else {
            return
        }

        plist[key] = value
        guard let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return
        }
        try? updated.write(to: url)
    }

    private func createDescriptorsSymlink(appHash: String, providerExtension: String) throws -> URL {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17 ? "61" : "59"
        return try createAppSymlink(for: "\(appHash)/Library/Application Support/PRBPosterExtensionDataStore/\(version)/Extensions/\(providerExtension)/descriptors")
    }

    private func createAppSymlink(for appHash: String) throws -> URL {
        try createSymlink(to: "/var/mobile/Containers/Data/Application/\(appHash)")
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
