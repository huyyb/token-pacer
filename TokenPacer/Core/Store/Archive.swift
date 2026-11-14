import Foundation
import os

/// What has to outlive the process.
///
/// The app was entirely stateless across launches, which cost more than it
/// looked: the refresh floor restarted with the process, so during development —
/// where a rebuild kills the app every few minutes — every launch spawned another
/// CLI, and the last reading was thrown away with it.
struct ArchivedState: Codable, Sendable {
    /// Bumped when a field's meaning changes. A state file from a newer version
    /// is ignored rather than guessed at.
    ///
    /// 3: the limits no longer come from the usage endpoint but from the CLI's
    /// own `/usage` panel, so the anchors and the calibration a version-2 file
    /// carries describe a reading this build cannot make. The event archive is a
    /// separate file and keeps its cursors, so this costs no cold start.
    static let currentVersion = 3

    var version = currentVersion
    var pollers: [SourceID: PanelPoller] = [:]
    /// The last reading itself, not just the tracker around it. Without it a
    /// relaunch has an anchor but nothing to report, so the pill has no figure
    /// at all until the next request is due — ten minutes of a blank, right
    /// after launch, for no reason.
    var limits: [SourceID: RateLimits] = [:]
    /// Why the last reading failed, if it did.
    ///
    /// The backoff outlives a launch and the reason used to not, so a relaunch
    /// inside the failure window restored "wait ten minutes" without restoring
    /// anything to show for it: a row reading "—", no message under it, and —
    /// because the refresh button is drawn for a complaint — nothing to press
    /// either. Optional so a version-3 file written before this field still
    /// decodes; it is a new fact about the same reading, not a changed one.
    var limitsErrors: [SourceID: String]?
    /// The build that wrote this file, as `1.1.2 (267)`.
    ///
    /// A backoff earned by one build is not evidence against the next: the
    /// failure it counts is usually the very bug the update fixed. Restored
    /// across an upgrade it held the fixed build to the broken one's schedule —
    /// up to an hour of a blank row before the first read. Optional, so a file
    /// from before this field loads, and reads as written by some other build.
    var appVersion: String?
    var savedAt = Date.now
}

/// Events and cursors: the expensive half.
///
/// A cold start reads ~700MB of JSONL across 500-odd files because the byte
/// cursors start empty. Archiving the events the store already holds — and where
/// each file was left — turns that into one read of a few megabytes plus whatever
/// has been appended since. Kept in its own file: it is a thousand times the size
/// of the limits state and is written a thousand times less often.
struct ArchivedEvents: Codable, Sendable {
    /// Bumped when the same log line decodes to a different event — a field
    /// derived differently, a line newly read. An older archive still loads,
    /// but its cursors are dropped and every log is read once more; the fresh
    /// events replace the archived ones by id, and an archived event whose log
    /// is gone is kept.
    ///
    /// 2: a project is the repository the directory is in, not the directory,
    /// and Codex before 0.153 is read off its `token_count` lines.
    static let currentVersion = 2

    struct PerSource: Codable, Sendable {
        var cursors: [String: JSONLReader.Cursor] = [:]
        var events: [UsageEvent] = []
        /// Optional so an archive from before the rollup still decodes.
        var rollup: UsageRollup?
    }

    var version = currentVersion
    var sources: [SourceID: PerSource] = [:]
    var savedAt = Date.now
}

/// One JSON file in Application Support. No database: this is a few hundred
/// bytes that are rewritten after a network call, not a log.
struct Archive: Sendable {
    var url: URL

    static let `default` = Archive(
        url: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TokenPacer/state.json")
    )

    func load() -> ArchivedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let state = try JSONDecoder.archive.decode(ArchivedState.self, from: data)
            // Exact, not "no newer than": an older file is what a bump exists to
            // reject. This state re-measures itself within one refresh, so
            // dropping it costs ten minutes. The *events* archive keeps the
            // looser guard — rebuilding that costs a 700MB cold start.
            guard state.version == ArchivedState.currentVersion else {
                Log.ingest.notice("archive version \(state.version, privacy: .public) is not \(ArchivedState.currentVersion, privacy: .public), ignored")
                return nil
            }
            return state
        } catch {
            // A truncated or hand-edited file is not worth failing a launch over.
            Log.ingest.error("archive unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Where events were archived before the append-only log: one JSON
    /// document, rewritten whole. Read once to migrate, then removed.
    var legacyEventsURL: URL { url.deletingLastPathComponent().appending(path: "events.json") }

    /// One `ArchivedEvents` per line, each a change on top of the lines before
    /// it: cursors overwrite, events add, a rollup replaces.
    ///
    /// Append-only because rewriting the whole archive every five minutes was
    /// the largest thing this app did — encoding tens of megabytes of JSON took
    /// the process to several times its resting footprint, for a save that
    /// usually carried a handful of new events. `saveEvents` still rewrites it
    /// whole, but on a cadence of megabytes appended rather than minutes.
    var eventLogURL: URL { url.deletingLastPathComponent().appending(path: "events.jsonl") }

    var hasEventLog: Bool { FileManager.default.fileExists(atPath: eventLogURL.path) }

    var eventLogBytes: Int {
        ((try? FileManager.default.attributesOfItem(atPath: eventLogURL.path))?[.size] as? Int) ?? 0
    }

    func loadEvents() -> ArchivedEvents? {
        // Mapped, not read: the file is paged in and dropped again rather than
        // copied into dirty memory the process keeps long after launch.
        guard let data = try? Data(contentsOf: eventLogURL, options: .mappedIfSafe)
        else { return loadLegacyEvents() }
        var folded = ArchivedEvents()
        var read = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // A line cut short by a crash mid-append costs that save, not the
            // archive: the lines either side of it are whole.
            guard let delta = try? JSONDecoder.archive.decode(ArchivedEvents.self, from: Data(line))
            else { continue }
            read += 1
            folded.version = min(folded.version, delta.version)
            for (id, change) in delta.sources {
                var into = folded.sources[id] ?? ArchivedEvents.PerSource()
                into.cursors.merge(change.cursors) { $1 }
                into.events.append(contentsOf: change.events)
                if let rollup = change.rollup { into.rollup = rollup }
                folded.sources[id] = into
            }
        }
        guard read > 0, folded.version <= ArchivedEvents.currentVersion else { return nil }
        // Appended a poll at a time, so ordered within a line but not
        // guaranteed across a resumed session's replay.
        for id in folded.sources.keys {
            folded.sources[id]?.events.sort { $0.timestamp < $1.timestamp }
        }
        return folded
    }

    private func loadLegacyEvents() -> ArchivedEvents? {
        guard let data = try? Data(contentsOf: legacyEventsURL) else { return nil }
        do {
            let archived = try JSONDecoder.archive.decode(ArchivedEvents.self, from: data)
            guard archived.version <= ArchivedEvents.currentVersion else { return nil }
            return archived
        } catch {
            // Re-reading the logs is slow, never wrong: a bad file costs a cold
            // start, not correctness.
            Log.ingest.error("event archive unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Adds one line on top of what is there.
    func appendEvents(_ delta: ArchivedEvents) {
        do {
            var line = try JSONEncoder.compact.encode(delta)
            line.append(0x0A)
            guard let handle = try? FileHandle(forUpdating: eventLogURL) else {
                return saveEvents(delta)
            }
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // A crash mid-append leaves no newline; without one this line would
            // join the torn one and be lost with it.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            }
            try handle.write(contentsOf: line)
        } catch {
            Log.ingest.error("event log unwritable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rewrites the log as the whole state. Encoded a slice at a time: one
    /// document of every event is what built the spike this format exists to
    /// avoid.
    func saveEvents(_ archived: ArchivedEvents) {
        do {
            var file = Data()
            for (id, state) in archived.sources {
                var head = ArchivedEvents(version: archived.version)
                head.sources[id] = ArchivedEvents.PerSource(cursors: state.cursors, rollup: state.rollup)
                file.append(try JSONEncoder.compact.encode(head))
                file.append(0x0A)
                for start in stride(from: 0, to: state.events.count, by: 2_000) {
                    var chunk = ArchivedEvents(version: archived.version)
                    chunk.sources[id] = ArchivedEvents.PerSource(
                        events: Array(state.events[start..<min(start + 2_000, state.events.count)])
                    )
                    file.append(try JSONEncoder.compact.encode(chunk))
                    file.append(0x0A)
                }
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try file.write(to: eventLogURL, options: .atomic)
            try? FileManager.default.removeItem(at: legacyEventsURL)
        } catch {
            Log.ingest.error("archive unwritable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save(_ state: ArchivedState) {
        var state = state
        state.savedAt = Date.now
        write(state, to: url, pretty: true)
    }

    private func write(_ value: some Encodable, to url: URL, pretty: Bool) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Atomic: a crash mid-write must not leave a half-written file that
            // the next launch then refuses.
            let encoder = pretty ? JSONEncoder.archive : JSONEncoder.compact
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.ingest.error("archive unwritable: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static let archive: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONEncoder {
    /// No whitespace for the big one; it is read by machines only.
    static let compact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let archive: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
