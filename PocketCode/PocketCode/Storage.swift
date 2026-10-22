import Foundation

/// App-private storage that can grow over time, for the Storage section in Settings.
enum StorageArea: String, CaseIterable, Identifiable {
    case pipCache, installedPackages, notebookPackages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pipCache: "pip Download Cache"
        case .installedPackages: "Installed Packages (pip)"
        case .notebookPackages: "Notebook Packages"
        }
    }

    var explanation: String {
        switch self {
        case .pipCache: "Downloaded files pip keeps to speed up reinstalls. Safe to clear; iOS also clears it when storage is low."
        case .installedPackages: "Packages installed with pip in the terminal. You'll need to pip install them again. Restart the app afterwards to fully unload them."
        case .notebookPackages: "numpy, pandas, matplotlib and other notebook packages, kept so notebooks work offline. They download again the next time a notebook imports them."
        }
    }

    var url: URL {
        let support = URL.applicationSupportDirectory.appending(path: "PocketCode")
        switch self {
        case .pipCache: return URL.cachesDirectory.appending(path: "pip")
        case .installedPackages: return support.appending(path: "site-packages")
        case .notebookPackages: return support.appending(path: "pyodide-\(AppSchemeHandler.pyodideVersion)")
        }
    }

    /// Total size in bytes (0 if missing).
    func size() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Empties the folder (keeps the folder itself so running code that expects it doesn't break).
    func clear() throws {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            try FileManager.default.removeItem(at: item)
        }
    }
}
