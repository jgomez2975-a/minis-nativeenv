//
//  verify/stubs/ISHCommandResult.swift
//
//  Stand-in for the two Minis types the graft touches:
//
//    struct ISHCommandResult { let output: String; let exitCode: Int }
//    actor ISHExecutionCoordinator { ... }   (declaration shape only)
//
//  NativeShellBackend builds an ISHCommandResult to satisfy the coordinator's
//  return type, so the memberwise init and both stored properties have to match
//  the real declaration exactly or the type-check proves nothing.
//

import Foundation

struct ISHCommandResult {
    let output: String
    let exitCode: Int
}
