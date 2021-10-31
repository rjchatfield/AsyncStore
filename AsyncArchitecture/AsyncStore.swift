import Foundation
import Combine
import SwiftUI

struct State {
    var history: [Action] = []
}

enum Action: Equatable {
    case featureInitialised
    case buttonTapped
    case dismissed

    case retrieveComplete
    case fetchComplete
    case subscriptionTick
}

enum Effect {
    case retrieveSomething
    case fetchSomething
    case saveSomething
    case subscribeToSomething
    case cancelSubscription

    func callAsFunction(/*environment: Environment*/) -> AnyAsyncSequence<Action> {
        switch self {
        case .retrieveSomething:
            return .single {
                .retrieveComplete
            }

        case .fetchSomething:
            return .makeCancellable(globalID: FetchCancellationID(), autoCancel: true) {
                do {
                    print("😴 .fetchSomething (0.3s)")
                    try await Task.sleep(nanoseconds: 300_000_000)
                    print(" 😳 .fetchSomething (0.3s)")
                    return .fetchComplete
                } catch {
                    print(" 💩 .fetchSomething - CANCELLED DURING SLEEP")
                    return nil
                }
            }

        case .saveSomething:
            return .none // but should be .fireAndForget

        case .subscribeToSomething:
            return Timer.publish(every: 0.1, on: .main, in: .default)
                .autoconnect()
                .asAnyAsyncSequence()
                .map { _ in .subscriptionTick }
                .makeCancellable(globalID: TimerCancellationID(), autoCancel: true)

        case .cancelSubscription:
            return .fireAndForget {
                TimerCancellationID().cancel()
            }
        }
    }
}

// MARK: -

/// Public wrapper around privately held structured core.
/// All detacted async tasks will be cancelled when class is deinit.
@MainActor
final class AsyncStore {
//actor AsyncStore {

    var state: State { structured.state }
    private let structured = StructuredCore()
    private var cancellables: Set<AnyCancellable> = []

    /// Public API
    /// Performs state mutation immediately without async hop
    /// But then detaches task to handle effects and reactions using structured concurrecny = managing memory and cancellation
    func send(_ action: Action, _ counter: String) {
        print("Start of send(_:)")
        print(counter, "SEND", action)
        let effects = structured.reducer(&structured.state, action)
        Task { @MainActor [structured] in
            await structured.structuredHandle(effects: effects, counter)
            // TODO: De-register from `cancellables`?
        }
        .store(in: &cancellables) // cancel detached task on deinit
        print("End   of send(_:)")
    }

    /// Private class that performs all structured async tasks, separate from public class to avoid retain cycles.
    /// All detached tasks may retain this private class, and will be cancelled when public class is deinit.
    @MainActor
    private final class StructuredCore {

        var state = State()
        let reducer: (inout State, Action) -> [Effect] = { state, action in
            state.history.append(action)
            switch action {
            case .featureInitialised:
                return [
                    .subscribeToSomething,
                    .fetchSomething,
                ]
            case .buttonTapped:
                return [
                    .fetchSomething
    //                .saveSomething,
                ]
            case .dismissed:
                return [
                    .cancelSubscription
                ]
            case .subscriptionTick:
                return []
            case .retrieveComplete:
                return []
            case .fetchComplete:
                return [
                    .saveSomething,
                ]
            }
        }

        /// Async function for performing state mutation
        /// Handles effects with structured concurrency without detached task
        func structuredSend(_ action: Action, _ counter: String) async {
            print("Start of structuredSend(_:)", counter, action)
            let effects = reducer(&state, action)
            await structuredHandle(effects: effects, counter)
            print("End   of structuredSend(_:)", counter, action)
        }

        /// Use TaskGroup to maintain structured concurrency
        /// Synchronously loop through all `Effects` and handle each `Effect` as a task added to the group
        func structuredHandle(effects: [Effect], _ counter: String) async {
            print(" Start of structuredHandle(effects:)", counter, "+", effects.count)
            await withTaskGroup(of: Void.self) { [weak self] group in
                print("  Start of structuredHandle(effects:) TaskGroup", counter, "+", effects.count)
                for (i, effect) in effects.enumerated() {
                    let effectCounter = counter + ".\(i + 1)"
                    print(" ", effectCounter, "", effect, "...")
                    group.addTask { [weak self] in
                        await self?.structuredHandle(effect: effect, effectCounter)
                    }
                }
                await group.waitForAll()
                print("  End   of structuredHandle(effects:) TaskGroup", counter, "+", effects.count)
            }
            print(" End   of structuredHandle(effects:)", counter, "+", effects.count)
        }

        /// Use `TaskGroup` to maintain structured concurrency
        /// Asynchronously loop through each ReAction one-by-one, and handle eeach ReAction as a task added to the group
        func structuredHandle(effect: Effect, _ effectCounter: String) async {
            print("   Start of structuredHandle(effect:)", effectCounter, effect)
            await withTaskGroup(of: Void.self) { [weak self] group in
                print("    Start of structuredHandle(effect:) TaskGroup", effectCounter, "...", effect)
                do {
                    var i = 1
                    for try await reaction in effect() {
                        try Task.checkCancellation()
                        let reactionCounter = effectCounter + ".\(i)"
                        i += 1
                        print(reactionCounter, " REACTION", reaction)
                        group.addTask { [weak self] in
                            await self?.structuredSend(reaction, reactionCounter)
                        }
                    }
                } catch {
                    print("handle(effect:) something threw?", error)
                }
                await group.waitForAll()
                print("    End   of structuredHandle(effect:) TaskGroup", effectCounter, "...", effect)
            }
            print("   End   of structuredHandle(effect:)", effectCounter, effect)
        }
    }
}

extension Task {
    func store(in cancellables: inout Set<AnyCancellable>) {
        cancellables.insert(AnyCancellable {
            print("Task.cancel()")
            cancel()
        })
    }
}

// MARK: -

struct AnyAsyncSequence<Element>: AsyncSequence {
    let _makeAsyncIterator: @Sendable () -> AsyncIterator

    func makeAsyncIterator() -> AsyncIterator {
        _makeAsyncIterator()
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let _next: () async throws -> Element?
        func next() async throws -> Element? {
            do {
                return try await _next()
            } catch {
                print(".AsyncIterator something threw?", error)
                throw error
            }
        }
    }
}

extension AnyAsyncSequence {
    init<Seq: AsyncSequence>(_ asyncSequence: Seq) where Seq.Element == Element {
        _makeAsyncIterator = {
            var it = asyncSequence.makeAsyncIterator()
            return AsyncIterator(_next: {
                try await it.next()
            })
        }
    }

    static var none: Self {
        AnyAsyncSequence(_makeAsyncIterator: {
            AsyncIterator(_next: { nil })
        })
    }

    // naming "Just"?
    static func single(_ element: Element) -> Self {
        .single { element }
    }

    static func single(_ element: @escaping () async -> Element?) -> Self {
        AnyAsyncSequence(_makeAsyncIterator: {
            var once = true
            return AsyncIterator(_next: { () async -> Element? in
                guard once else {
                    return nil
                }
                once = false
                return await element()
            })
        })
    }

    static func fireAndForget(_ block: @escaping () async -> Void) -> Self {
        AnyAsyncSequence(_makeAsyncIterator: {
            AsyncIterator(_next: {
                await block()
                return nil
            })
        })
    }

    static func makeCancellable<ID: CancellationID>(
        globalID: ID,
        autoCancel: Bool,
        _ element: @escaping () async -> Element?
    ) -> Self {
        Self.single(element)
            .makeCancellable(globalID: globalID, autoCancel: autoCancel)
    }

    func makeCancellable<ID: CancellationID>(
        globalID: ID,
        autoCancel: Bool
    ) -> Self {
        if autoCancel {
            globalID.cancel()
        }
        return AnyAsyncSequence(_makeAsyncIterator: {
            let it = _makeAsyncIterator()
            let streamToken = InvalidationToken()
            return AnyAsyncSequence.AsyncIterator(_next: { () async throws -> Element? in
                let elementHandle = Task { () async throws -> Element? in
                    return try await it.next()
                }
                /// Each `Task` must be cancellable to ensure we clean up all underlying work
                /// Additionally, an invalidation token is used to halt the Stream
                globalID.globalRegister {
                    elementHandle.cancel()
                    await streamToken.invalidate()
                }
                defer { globalID.globalDeregister() }
                let result = try await elementHandle.value
                guard await streamToken.isValid else { return nil }
                return result
            })
        })
    }
}

actor InvalidationToken {
    var isValid = true

    func invalidate() {
        print("InvalidationToken.invalidate()")
        isValid = false
    }
}

extension AsyncSequence {
    func makeCancellable<ID: CancellationID>(
        globalID: ID,
        autoCancel: Bool
    ) -> AnyAsyncSequence<Element> {
        AnyAsyncSequence(self)
            .makeCancellable(globalID: globalID, autoCancel: autoCancel)
    }
}

extension Publisher where Failure == Never {
    func asAnyAsyncSequence() -> AnyAsyncSequence<Output> {
        AnyAsyncSequence(values)
    }
}

// MARK: -

struct FetchCancellationID: CancellationID {
    static var _counter = 0
    static var counter: Int {
        get {
            let c = _counter
            _counter += 1
            return c
        }
    }
    let i = Self.counter
}
struct TimerCancellationID: CancellationID {
    static var _counter = 0
    static var counter: Int {
        get {
            let c = _counter
            _counter += 1
            return c
        }
    }
    let i = Self.counter
}
struct StoreTaskCancellationID: CancellationID {
    static var _counter = 0
    static var counter: Int {
        get {
            let c = _counter
            _counter += 1
            return c
        }
    }
    let i = Self.counter
}

protocol CancellationID: Hashable, Sendable {}
extension CancellationID {
    func cancel() {
        Task { @MainActor in
            guard let cancel = allCancelBlocks.removeValue(forKey: self) else { return }
            await cancel()
            print("... CANCELLED:", self)
        }
    }

    func globalRegister(cancel: @escaping @Sendable () async -> Void) {
        Task { @MainActor in
            // Register cancellable
            allCancelBlocks[self] = cancel
            print("... REGISTERED:", self)
        }
    }

    func globalDeregister() {
        Task { @MainActor in
            allCancelBlocks[self] = nil
            print("... de-REGISTERED:", self)
        }
    }
}

@MainActor
var allCancelBlocks: [AnyHashable: () async -> Void] = [:]
