import Foundation
import Combine

struct State {
}

enum Action {
    case featureInitialised
    case buttonTapped

    case subscriptionTick
    case retrieveComplete
    case fetchComplete
}

enum Effect {
    case subscribeToSomething
    case retrieveSomething
    case fetchSomething
    case saveSomething

    func callAsFunction() async -> Action? {
        switch self {
        case .subscribeToSomething:
            do {
                print("😴 .subscribeToSomething (1.5s)")
                try await Task.sleep(nanoseconds: 1_500_000_000)
                print(" 😳 .subscribeToSomething (1.5s)")
                return .subscriptionTick
            } catch {
                return nil
            }
        case .retrieveSomething:
            return .retrieveComplete
        case .fetchSomething:
            do {
                print("😴 .fetchSomething (0.3s)")
                try await Task.sleep(nanoseconds: 300_000_000)
                print(" 😳 .fetchSomething (0.3s)")
                return .fetchComplete
            } catch {
                return nil
            }
        case .saveSomething:
            return nil
        }
    }

    func getReactions() -> ReactionSequence {
        switch self {
        case .subscribeToSomething:
            return .publisher(
                Timer.publish(every: 0.1, on: .main, in: .default)
                    .autoconnect()
                    .map { _ in .subscriptionTick }
            )
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
                for await reaction in effect.getReactions() {
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
