//
//  PolishEditor.swift
//  Whisperer
//
//  The one place the mmBERT editor is built, loaded, and handed to the polish pipeline.
//
//  Three constraints shape this, and each of them rules out the obvious implementation:
//
//  1. **The weights may not be on disk.** They are fetched on first launch by
//     `PolishModelManager`, so on a fresh install there is no editor for the first minute of the
//     app's life, and possibly for much longer on a bad link. Every caller therefore has to
//     tolerate `nil`, and `nil` has to mean "polish deterministically" rather than "fail".
//  2. **Loading is slow and must never be awaited on the dictation path.** Compiling the
//     `.mlpackage` and instantiating the `MLModel` is seconds. The user's utterance ends and the
//     text must appear; a first dictation that blocks on a Core ML compile is a worse product
//     than one that skips the editor. So `current()` never waits — it returns the editor if the
//     load has already finished and `nil` if it has not, and the load itself is kicked off ahead
//     of time by `prepare()`.
//  3. **One instance, process-wide.** The model is 143 MB resident. `DeterministicPolisher` is a
//     value type rebuilt per recording (and per meeting card), so an editor owned by the polisher
//     would be re-instantiated on that cadence.
//
//  Not an actor, for the same reason `MMBERTCoreMLRuntime` is not: `current()` has to be a
//  synchronous read from `DeterministicPolisher.forTranscript`, which is itself synchronous and
//  called from several isolation domains. The lock guards two references and is never held across
//  an await.
//

import Foundation

enum PolishEditor {

    /// Guards `state`. Never held across `await`.
    private static let lock = NSLock()
    private static var state: State = .idle

    private enum State {
        case idle
        /// A load is in flight. Nothing waits on it; `current()` keeps returning nil until it
        /// lands, which is the whole point of not making this awaitable.
        case loading
        case ready(MMBERTEditingModel)
        /// The weights are absent or the load threw. Recorded so `prepare()` does not retry on
        /// every utterance — a missing model is not a transient condition, and a Core ML compile
        /// failure repeated per utterance is a CPU leak with no upside. `reset()` clears it, and
        /// `PolishModelManager` calls that when a download completes.
        case unavailable
    }

    // MARK: - Reads

    /// The editor, if it is loaded *right now*. Never blocks, never loads on demand.
    ///
    /// Returning `nil` is an ordinary answer and not an error: it is what every caller sees until
    /// the first load completes, and what they see forever if the user never downloads the model.
    /// The pipeline that results is exactly the deterministic one that shipped before this
    /// existed.
    static func current() -> (any EditingModel)? {
        guard PolishFeatureFlags.isEditorEnabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        if case .ready(let model) = state { return model }
        return nil
    }

    /// Whether an editor is loaded, for the polish log line.
    static var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .ready = state { return true }
        return false
    }

    // MARK: - Loading

    /// Begin loading if the weights are present and nothing is loaded or in flight.
    ///
    /// Idempotent and safe to call from anywhere, including per utterance. Called at launch, when
    /// a download finishes, and defensively from the polish path so that a build which never got
    /// a launch call still converges.
    static func prepare() {
        guard PolishFeatureFlags.isEditorEnabled else { return }

        lock.lock()
        switch state {
        case .loading, .ready, .unavailable:
            lock.unlock()
            return
        case .idle:
            break
        }
        guard let runtime = MMBERTCoreMLRuntime.makeIfAvailable() else {
            // No weights yet. Stay `.idle` rather than going `.unavailable`: the download may
            // still be running, and `PolishModelManager` will call `prepare()` again when it
            // lands. `.unavailable` is for a load that was attempted and failed.
            lock.unlock()
            return
        }
        state = .loading
        lock.unlock()

        Task.detached(priority: .utility) {
            do {
                try await runtime.load()

                // Loading an `MLModel` does not build its GPU graph. Core ML defers that to the
                // first `prediction()`, where `MPSGraphExecutable specializedModuleWithDevice`
                // compiles the whole thing — measured at 2.0 s, and it landed between `rec.stop`
                // and the paste on the first dictation of every launch, which is the single worst
                // moment to spend it. One throwaway encode here moves it to launch, where nothing
                // is waiting. Failure is ignored on purpose: a warm-up that throws says nothing
                // about whether a real encode will, and refusing to publish the model over it
                // would trade a one-time stall for no editor at all.
                _ = try? await runtime.encode(["warm"])

                let model = MMBERTEditingModel(runtime: runtime)
                lock.lock()
                state = .ready(model)
                lock.unlock()
                Logger.info("Polish editor ready", subsystem: .transcription)
            } catch {
                lock.lock()
                state = .unavailable
                lock.unlock()
                Logger.error("Polish editor failed to load: \(error)", subsystem: .transcription)
            }
        }
    }

    /// Drop whatever is loaded and allow `prepare()` to try again.
    ///
    /// Called when a model download completes, which is the one moment a previous "no weights"
    /// or failed-load verdict is known to be stale.
    static func reset() {
        lock.lock()
        state = .idle
        lock.unlock()
    }
}
