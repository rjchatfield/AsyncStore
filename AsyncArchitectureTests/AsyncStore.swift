import Foundation
import Combine

struct State {
}

enum Action {
    case featureInitialised
    case buttonTapped
    case dismissed

    case subscriptionTick
    case retrieveComplete
    case fetchComplete
}

enum Effect {
    case subscribeToSomething
    case cancelSubscription
    case retrieveSomething
    case fetchSomething
    case saveSomething

    func callAsFunction() -> ReactionSequence {
        switch self {
        case .subscribeToSomething:
            return .publisher(
                Timer.publish(every: 0.1, on: .main, in: .default)
                    .autoconnect()
                    .map { _ in .subscriptionTick }
            )
            .makeCancellable(globalID: TimerCancellationID())
        case .cancelSubscription:
            return .fireAndForget {
//                CancellationID.cancel(globalID: TimerCancellationID())
                TimerCancellationID().cancel()
            }
        case .retrieveSomething:
            return .single {
                .retrieveComplete
            }
        case .fetchSomething:
            return .single {
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
            return .none
        }

    }
}

struct TimerCancellationID: CancellationID {}

protocol CancellationID: Hashable {}
extension CancellationID {
    func cancel() {
        Task { @MainActor in
            guard let task = allCancellables.removeValue(forKey: self) else { return }
            task.cancel()
            print("CANCELLED:", self)
        }
    }
}

@MainActor
var allCancellables: [AnyHashable: AnyCancellable] = [:]

enum ReactionSequence: AsyncSequence {

    case none
    case single(() async -> Action?)
    case stream((AsyncStream<Action>.Continuation) -> Void)

    static func asyncSequence<Seq: AsyncSequence>(_ seq: Seq) -> Self where Seq.Element == Action {
        .stream { continuation in
            Task {
                do {
                    for try await value in seq {
                        continuation.yield(value)
                    }
                } catch {
                    // can't handle error. just finish.
                }
                continuation.finish()
            }
        }
    }

    static func publisher<P: Publisher>(_ p: P) -> Self where P.Output == Action, P.Failure == Never {
        .asyncSequence(p.values)
    }

    static func fireAndForget(_ block: @escaping () async -> Void) -> Self {
        .single {
            Task {
                await block()
            }
            return nil
        }
    }

    func makeCancellable<ID: CancellationID>(globalID: ID) -> ReactionSequence {
        .stream { continuation in
            let task = Task {
                for await value in self {
                    continuation.yield(value)
                }
                continuation.finish()
                Task { @MainActor in
                    allCancellables[globalID] = nil
                }
            }
            Task { @MainActor in
                allCancellables[globalID] = AnyCancellable { task.cancel() }
            }
        }
    }

    typealias AsyncIterator = AsyncStream<Action>.AsyncIterator
    typealias Element = Action

    func makeAsyncIterator() -> AsyncStream<Action>.AsyncIterator {
        AsyncStream { continuation in
            switch self {
            case .none:
                continuation.finish()

            case .single(let reactionBlock):
                Task {
                    if let reaction = await reactionBlock() {
                        continuation.yield(reaction)
                    }
                    continuation.finish()
                }

            case .stream(let reactionsBlock):
                reactionsBlock(continuation)
            }
        }.makeAsyncIterator()
    }
}

/*
 TODO:

 Basic impl - single async action


 Interleave ReActions

 Cancellation
 */

@MainActor
final class AsyncStore {
//actor AsyncStore {

    private(set) var state = State()
    private let reducer: (Action) -> [Effect] = { action in
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

    func send(_ action: Action, _ counter: String) async {
        print(counter, "SEND", action)
        let effects = reducer(action)
        print(counter, "+", effects.count)
        for (i, effect) in effects.enumerated() {
            let effectCounter = counter + ".\(i + 1)"
            print(effectCounter, "", effect, "...")
//            Task(priority: .high) {
            Task {
                print(effectCounter, "...", effect)
                var i = 1
                for await reaction in effect() {
                    let reactionCounter = effectCounter + ".\(i)"
                    i += 1
                    print(reactionCounter, " REACTION", reaction)
                    Task {
                        await send(reaction, reactionCounter)
                    }
                }
            }
        }
    }
}
