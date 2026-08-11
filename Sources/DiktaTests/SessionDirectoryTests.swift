import Foundation

@testable import DiktaCore

/// The collision rule the save panel already used, now also reached by
/// `dikta record -o` — worth pinning down, because getting it wrong either
/// overwrites somebody's lecture or litters "(2)" folders forever.
func registerSessionDirectoryTests(_ runner: TestRunner) {
    let manager = FileManager.default

    runner.test("session dir: a free path is used as-is") { context in
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("session", isDirectory: true)
            context.expectEqual(
                RecordingCoordinator.uniquified(target).lastPathComponent, "session")
        }
    }

    runner.test("session dir: an existing empty directory is reused") { context in
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("session", isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            context.expectEqual(
                RecordingCoordinator.uniquified(target).lastPathComponent, "session",
                "an empty directory should be reused rather than suffixed")
        }
    }

    runner.test("session dir: a directory holding a recording is never overwritten") { context in
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("session", isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("# index".utf8).write(to: target.appendingPathComponent("index.md"))

            context.expectEqual(
                RecordingCoordinator.uniquified(target).lastPathComponent, "session (2)")

            // And it keeps counting rather than stopping at (2).
            let second = directory.appendingPathComponent("session (2)", isDirectory: true)
            try manager.createDirectory(at: second, withIntermediateDirectories: true)
            try Data("# index".utf8).write(to: second.appendingPathComponent("index.md"))
            context.expectEqual(
                RecordingCoordinator.uniquified(target).lastPathComponent, "session (3)")
        }
    }

    runner.test("session dir: a file in the way also forces a suffix") { context in
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("session", isDirectory: true)
            try Data("not a directory".utf8).write(to: target)
            context.expectEqual(
                RecordingCoordinator.uniquified(target).lastPathComponent, "session (2)")
        }
    }

    runner.test("session dir: root and name are honoured, with dated defaults") { context in
        try await withTemporaryDirectory { directory in
            let named = RecordingCoordinator.resolveSessionDirectory(
                root: directory, name: "lecture")
            context.expectEqual(named.lastPathComponent, "lecture")
            context.expectEqual(named.deletingLastPathComponent().standardizedFileURL.path,
                                directory.standardizedFileURL.path)

            // No name falls back to the same default the save panel offers.
            let date = Date(timeIntervalSince1970: 1_770_000_000)
            let dated = RecordingCoordinator.resolveSessionDirectory(root: directory, date: date)
            context.expectEqual(dated.lastPathComponent,
                                RecordingCoordinator.defaultSessionName(date: date))

            // An empty --name is treated as absent rather than as "".
            let blank = RecordingCoordinator.resolveSessionDirectory(
                root: directory, name: "", date: date)
            context.expectEqual(blank.lastPathComponent,
                                RecordingCoordinator.defaultSessionName(date: date))
        }
    }

    runner.test("session dir: the default name is stable and filesystem-safe") { context in
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let name = RecordingCoordinator.defaultSessionName(date: date)
        context.expect(name.hasPrefix("הקלטה "), "unexpected prefix: \(name)")
        // A colon would read as a path separator in Finder; the format uses a dot.
        context.expect(!name.contains(":"), "the name must not contain a colon: \(name)")
        context.expect(!name.contains("/"), "the name must not contain a slash: \(name)")
        context.expectEqual(RecordingCoordinator.defaultSessionName(date: date), name,
                            "the same date must produce the same name")
    }
}
