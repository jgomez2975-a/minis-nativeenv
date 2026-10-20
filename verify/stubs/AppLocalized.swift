//
//  verify/stubs/AppLocalized.swift
//
//  Stand-in for Minis' localisation helper, used only by the CI type-check of
//  the graft.
//
//  The real declaration is
//
//      func AppLocalized(_ key: String.LocalizationValue,
//                        comment: StaticString? = nil) -> String
//
//  Keeping `String.LocalizationValue` rather than widening it to `String` is the
//  point: the parameter type is what decides whether a call site compiles with a
//  string literal, an interpolated literal, or a runtime value. A laxer stub
//  would accept call sites that fail in the app target.
//

import Foundation

func AppLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    // The type-check never runs this; the real bundle lookup happens in the app.
    ""
}
