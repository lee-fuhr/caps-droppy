//
//  CapsdroppyHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import DroppyKit
import DroppyKitHarness
import Capsdroppy

@main
struct CapsdroppyHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { CapsdroppyDroplet() }
}
