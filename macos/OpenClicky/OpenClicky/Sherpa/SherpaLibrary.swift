//
//  SherpaLibrary.swift
//  OpenClicky
//
//  sherpa-onnx's C library, opened with dlopen from the app's Frameworks folder (it ships there,
//  see scripts/embed-kokoro-engine.sh) inside a helper process. libonnxruntime.dylib sits beside
//  it and is found through its @loader_path rpath.
//

import Foundation

nonisolated struct SherpaLibrary {
    private let handle: UnsafeMutableRawPointer

    /// The engine inside the app.
    static var folder: URL { Bundle.main.privateFrameworksURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks") }

    /// Whether both libraries are in `folder`.
    static func isEmbedded(in folder: URL = folder) -> Bool {
        ["libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    static func open(in folder: URL) throws -> SherpaLibrary {
        let path = folder.appendingPathComponent("libsherpa-onnx-c-api.dylib").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw SherpaLibraryError.notLoaded(String(cString: dlerror()))
        }
        return SherpaLibrary(handle: handle)
    }

    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw SherpaLibraryError.notLoaded("\(name) is missing") }
        return unsafeBitCast(pointer, to: type)
    }
}

nonisolated enum SherpaLibraryError: Error, LocalizedError, Equatable {
    case notLoaded(String)

    var errorDescription: String? {
        switch self {
        case let .notLoaded(reason): return "the speech engine didn't load: \(reason)"
        }
    }
}
