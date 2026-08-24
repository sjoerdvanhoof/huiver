import CryptoKit
import Foundation

public struct LanguagePackLicense: Codable, Sendable, Hashable {
    public let component: String
    public let version: String
    public let sourceURL: String
    public let license: String
    public let attribution: String
    public let sourceHash: String

    public init(
        component: String, version: String, sourceURL: String, license: String,
        attribution: String, sourceHash: String
    ) {
        self.component = component
        self.version = version
        self.sourceURL = sourceURL
        self.license = license
        self.attribution = attribution
        self.sourceHash = sourceHash
    }
}

/// The signed, data-only contract between a language pack and the compiled app.
/// `signature` covers the canonical JSON representation with that field omitted.
public struct LanguagePackManifest: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let languageCode: String
    public let version: String
    public let minimumCoreSchema: Int
    public let backendIdentifier: String
    public let localeProfiles: [String]
    public let files: [String: String]
    public let keyId: String
    public let signature: String?

    public init(
        schemaVersion: Int = 1, languageCode: String, version: String,
        minimumCoreSchema: Int = 1, backendIdentifier: String,
        localeProfiles: [String], files: [String: String], keyId: String,
        signature: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.languageCode = languageCode.lowercased()
        self.version = version
        self.minimumCoreSchema = minimumCoreSchema
        self.backendIdentifier = backendIdentifier
        self.localeProfiles = localeProfiles
        self.files = files
        self.keyId = keyId
        self.signature = signature
    }

    fileprivate var unsigned: LanguagePackManifest {
        .init(
            schemaVersion: schemaVersion, languageCode: languageCode, version: version,
            minimumCoreSchema: minimumCoreSchema, backendIdentifier: backendIdentifier,
            localeProfiles: localeProfiles, files: files, keyId: keyId
        )
    }
}

public struct LanguagePackDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(languageCode)-\(version)" }
    public let languageCode: String
    public let version: String
    public let backendIdentifier: String
    public let localeProfiles: [String]
    public let active: Bool
    public let installedSize: Int64
}

public struct LanguagePackCatalogEntry: Codable, Sendable, Hashable {
    public let languageCode: String
    public let version: String
    public let archiveURL: URL
    public let archiveSHA256: String
    public let compressedSize: Int64
}

public struct LanguagePackCatalog: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let packs: [LanguagePackCatalogEntry]
    public let keyId: String
    public let signature: String?

    fileprivate var unsigned: LanguagePackCatalog {
        .init(
            schemaVersion: schemaVersion, generatedAt: generatedAt, packs: packs,
            keyId: keyId, signature: nil
        )
    }
}

/// Validates and atomically activates signed `.narcissepack` archives. Packs
/// are deliberately data-only; processor implementations stay in HuiverKit.
public actor LanguagePackManager {
    public static let manifestName = "manifest.json"
    public static let licensesName = "LICENSES.json"
    public static let coreSchema = 1

    private struct Active: Codable { var versions: [String: String] }

    private let root: URL
    private let trustedKeys: [String: Curve25519.Signing.PublicKey]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(root: URL, trustedPublicKeys: [String: Data]) throws {
        self.root = root.appendingPathComponent("LanguagePacks", isDirectory: true)
        self.trustedKeys = try trustedPublicKeys.mapValues {
            try Curve25519.Signing.PublicKey(rawRepresentation: $0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func installed() throws -> [LanguagePackDescriptor] {
        let active = try readActive()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [LanguagePackDescriptor] = []
        for language in try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) where language.hasDirectoryPath && language.lastPathComponent != ".staging" {
            for version in try FileManager.default.contentsOfDirectory(
                at: language, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) where version.hasDirectoryPath {
                let manifestURL = version.appendingPathComponent(Self.manifestName)
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(LanguagePackManifest.self, from: data)
                else { continue }
                result.append(.init(
                    languageCode: manifest.languageCode, version: manifest.version,
                    backendIdentifier: manifest.backendIdentifier,
                    localeProfiles: manifest.localeProfiles,
                    active: active.versions[manifest.languageCode] == manifest.version,
                    installedSize: directorySize(version)
                ))
            }
        }
        return result.sorted { ($0.languageCode, $0.version) < ($1.languageCode, $1.version) }
    }

    @discardableResult
    public func install(archive data: Data) throws -> LanguagePackDescriptor {
        let zip = try Zip(data: data)
        try validateEntryNames(zip.entries.map(\.name))
        guard let manifestData = try zip.read(Self.manifestName) else {
            throw PackError.missing(Self.manifestName)
        }
        let manifest = try decoder.decode(LanguagePackManifest.self, from: manifestData)
        try validate(manifest: manifest)

        let expected = Set(manifest.files.keys).union([Self.manifestName])
        let actual = Set(zip.entries.map(\.name).filter { !$0.hasSuffix("/") })
        guard actual == expected else { throw PackError.unlistedFiles }
        guard manifest.files[Self.licensesName] != nil else {
            throw PackError.missing(Self.licensesName)
        }

        for (path, expectedHash) in manifest.files {
            guard let file = try zip.read(path) else { throw PackError.missing(path) }
            guard sha256(file) == expectedHash.lowercased() else { throw PackError.hashMismatch(path) }
        }
        guard let licensesData = try zip.read(Self.licensesName),
              let licenses = try? decoder.decode([LanguagePackLicense].self, from: licensesData),
              !licenses.isEmpty
        else { throw PackError.invalidLicenses }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var installed = false
        defer { if !installed { try? fileManager.removeItem(at: staging) } }

        for entry in zip.entries where !entry.name.hasSuffix("/") {
            let destination = staging.appendingPathComponent(entry.name)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try zip.read(entry).write(to: destination, options: [.atomic])
        }

        let languageRoot = root.appendingPathComponent(manifest.languageCode, isDirectory: true)
        try fileManager.createDirectory(at: languageRoot, withIntermediateDirectories: true)
        let target = languageRoot.appendingPathComponent(manifest.version, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) { throw PackError.alreadyInstalled }
        try fileManager.moveItem(at: staging, to: target)

        var active = try readActive()
        active.versions[manifest.languageCode] = manifest.version
        do {
            try writeActive(active)
            installed = true
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
        return .init(
            languageCode: manifest.languageCode, version: manifest.version,
            backendIdentifier: manifest.backendIdentifier,
            localeProfiles: manifest.localeProfiles, active: true,
            installedSize: directorySize(target)
        )
    }

    public func activate(languageCode: String, version: String) throws {
        let target = root.appendingPathComponent(languageCode.lowercased())
            .appendingPathComponent(version)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw PackError.notInstalled
        }
        var active = try readActive()
        active.versions[languageCode.lowercased()] = version
        try writeActive(active)
    }

    public func remove(languageCode: String, version: String) throws {
        let language = languageCode.lowercased()
        let active = try readActive()
        guard active.versions[language] != version else { throw PackError.cannotRemoveActive }
        let target = root.appendingPathComponent(language).appendingPathComponent(version)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    public func verifyCatalog(_ data: Data) throws -> LanguagePackCatalog {
        let catalog = try decoder.decode(LanguagePackCatalog.self, from: data)
        guard catalog.schemaVersion == 1 else { throw PackError.incompatibleSchema }
        guard let signature = catalog.signature else { throw PackError.invalidSignature }
        try verify(signature: signature, keyId: catalog.keyId, data: try encoder.encode(catalog.unsigned))
        return catalog
    }

    public func cacheCatalog(_ data: Data) throws {
        _ = try verifyCatalog(data)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
    }

    public func cachedCatalog() -> LanguagePackCatalog? {
        let url = root.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? verifyCatalog(data)
    }

    /// Refreshes the signed release catalog. Failure leaves the last valid
    /// cached catalog and every installed pack untouched.
    @discardableResult
    public func updateCatalog(from url: URL) async throws -> LanguagePackCatalog {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PackError.catalogDownloadFailed
        }
        let catalog = try verifyCatalog(data)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
        return catalog
    }

    @discardableResult
    public func install(_ entry: LanguagePackCatalogEntry) async throws -> LanguagePackDescriptor {
        let (data, response) = try await URLSession.shared.data(from: entry.archiveURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PackError.catalogDownloadFailed
        }
        guard sha256(data) == entry.archiveSHA256.lowercased() else {
            throw PackError.archiveHashMismatch
        }
        let descriptor = try install(archive: data)
        guard descriptor.languageCode == entry.languageCode.lowercased(),
              descriptor.version == entry.version
        else { throw PackError.catalogMismatch }
        return descriptor
    }

    private func validate(manifest: LanguagePackManifest) throws {
        guard manifest.schemaVersion == 1, manifest.minimumCoreSchema <= Self.coreSchema else {
            throw PackError.incompatibleSchema
        }
        guard ["en", "nl"].contains(manifest.languageCode),
              manifest.localeProfiles.allSatisfy({ LocaleProfile($0).languageCode == manifest.languageCode }),
              !manifest.version.isEmpty, !manifest.backendIdentifier.isEmpty
        else { throw PackError.invalidManifest }
        guard let signature = manifest.signature else { throw PackError.invalidSignature }
        try verify(signature: signature, keyId: manifest.keyId, data: try encoder.encode(manifest.unsigned))
        try validateEntryNames(Array(manifest.files.keys))
    }

    private func verify(signature: String, keyId: String, data: Data) throws {
        guard let key = trustedKeys[keyId], let bytes = Data(base64Encoded: signature),
              key.isValidSignature(bytes, for: data)
        else { throw PackError.invalidSignature }
    }

    private func validateEntryNames(_ names: [String]) throws {
        guard Set(names).count == names.count else { throw PackError.duplicatePath }
        for name in names {
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
                  !components.contains(".."), !components.contains(".")
            else { throw PackError.unsafePath(name) }
        }
    }

    private func readActive() throws -> Active {
        let url = root.appendingPathComponent("active.json")
        guard let data = try? Data(contentsOf: url) else { return Active(versions: [:]) }
        return try decoder.decode(Active.self, from: data)
    }

    private func writeActive(_ active: Active) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(active).write(
            to: root.appendingPathComponent("active.json"), options: .atomic
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func directorySize(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let iterator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in iterator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    public enum PackError: LocalizedError {
        case missing(String), duplicatePath, unsafePath(String), unlistedFiles
        case incompatibleSchema, invalidManifest, invalidSignature, hashMismatch(String)
        case invalidLicenses, alreadyInstalled, notInstalled, cannotRemoveActive
        case catalogDownloadFailed, archiveHashMismatch, catalogMismatch

        public var errorDescription: String? {
            switch self {
            case .missing(let path): "Language pack is missing \(path)."
            case .duplicatePath: "Language pack contains duplicate paths."
            case .unsafePath(let path): "Language pack contains an unsafe path: \(path)."
            case .unlistedFiles: "Language pack contents do not match its manifest."
            case .incompatibleSchema: "Language pack requires an incompatible core schema."
            case .invalidManifest: "Language pack manifest is invalid."
            case .invalidSignature: "Language pack signature is invalid or untrusted."
            case .hashMismatch(let path): "Language pack resource was altered: \(path)."
            case .invalidLicenses: "Language pack has no valid resource license notices."
            case .alreadyInstalled: "This language-pack version is already installed."
            case .notInstalled: "That language-pack version is not installed."
            case .cannotRemoveActive: "Activate another version before removing this language pack."
            case .catalogDownloadFailed: "The language-pack catalog or archive could not be downloaded."
            case .archiveHashMismatch: "The downloaded language-pack archive was altered."
            case .catalogMismatch: "The downloaded language pack does not match its catalog entry."
            }
        }
    }
}
