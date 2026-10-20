//
//  verify/stubs/AppLogger.swift
//
//  Stand-in for Minis/Sources/Shared/AppLogger.swift, used only by the CI
//  type-check of the graft. The real type lives in the app target and is not
//  reachable from a host-side compile.
//
//  Shape matters: if this drifts from the real API, the type-check passes for
//  the wrong reason. The real declaration is
//
//      struct AppLogger {
//          init(category: String)
//          func debug(_ message: @autoclosure () -> String)
//          func info(_ message: String)
//          func notice(_ message: String)
//          func warning(_ message: String)
//          func error(_ message: String)
//          func fault(_ message: String)
//      }
//
//  `debug` takes an autoclosure there, so the stub keeps the same signature to
//  reproduce the same call-site rules rather than a laxer one.
//

import Foundation

struct AppLogger {
    private let category: String

    init(category: String) {
        self.category = category
    }

    func debug(_ message: @autoclosure () -> String) { _ = message() }
    func info(_ message: String) { _ = message }
    func notice(_ message: String) { _ = message }
    func warning(_ message: String) { _ = message }
    func error(_ message: String) { _ = message }
    func fault(_ message: String) { _ = message }
}
