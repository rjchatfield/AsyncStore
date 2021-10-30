import Foundation
import Combine
import SwiftUI

struct State {
}

enum Action {
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

@MainActor
final class AsyncStore {
//actor AsyncStore {

    private(set) var state = State()
    private let reducer: (inout State, Action) -> [Effect] = { state, action in
        switch action {
        case .featureInitialised:
            return [
                .subscribeToSomething,
                .fetchSomething,
            ]
        case .buttonTapped:
            return [
                .fetchSomething
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

    private var cancellables: Set<AnyCancellable> = []

    deinit {
        for cancellable in cancellables {
            cancellable.cancel()
        }
    }

    func send(_ action: Action, _ counter: String) {
        print(counter, "SEND", action)
        let effects = reducer(&state, action)
        print(counter, "+", effects.count)
        for (i, effect) in effects.enumerated() {
            let effectCounter = counter + ".\(i + 1)"
            print(effectCounter, "", effect, "...")
            Task {
                print(effectCounter, "...", effect)
                var i = 1
                for try await reaction in effect() {
                    try Task.checkCancellation()
                    let reactionCounter = effectCounter + ".\(i)"
                    i += 1
                    print(reactionCounter, " REACTION", reaction)
                    Task { @MainActor in
                        send(reaction, reactionCounter)
                    }
                    .store(in: &cancellables)
                }
            }
            .store(in: &cancellables)
        }

//        // Without logging... it's quite small
//        let effects = reducer(&state, action)
//        for effect in effects {
//            Task {
//                for await reaction in effect() {
//                    Task {
//                        send(reaction, reactionCounter)
//                    }
//                }
//            }
//        }
    }
}

extension Task {
    func store(in cancellables: inout Set<AnyCancellable>) {
        cancellables.insert(AnyCancellable { cancel() })
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
            try await _next()
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
            return AnyAsyncSequence.AsyncIterator(_next: { () async throws -> Element? in
                let handle = Task { () async throws -> Element? in
                    do {
                        if let element = try await it.next() {
                            return element
                        } else {
                            globalID.deregister()
                            return nil
                        }
                    } catch {
                        globalID.deregister()
                        throw error
                    }
                }
                globalID.register(handle)
                return try await handle.value
            })
        })
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

struct FetchCancellationID: CancellationID {}
struct TimerCancellationID: CancellationID {}

protocol CancellationID: Hashable, Sendable {}
extension CancellationID {
    func cancel() {
        Task { @MainActor in
            guard let task = allCancellables.removeValue(forKey: self) else { return }
            task.cancel()
            print("CANCELLED:", self)
        }
    }

    func register<Element, Failure>(_ handle: Task<Element?, Failure>) {
        Task { @MainActor in
            // Register cancellable
            allCancellables[self] = AnyCancellable {
                handle.cancel()
            }
        }
    }

    func deregister() {
        Task { @MainActor in
            allCancellables[self] = nil
        }
    }
}

@MainActor
var allCancellables: [AnyHashable: AnyCancellable] = [:]
