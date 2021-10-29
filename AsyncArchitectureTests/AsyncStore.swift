//
//  AsyncStore.swift
//  AsyncStore
//
//  Created by Rob Chatfield on 29/10/21.
//

import Foundation

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
}

//struct ReactionSequence: AsyncSequence {
//
//}

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
                if let reaction = await effect() {
                    print(effectCounter, " REACTION", reaction)
                    await send(reaction, effectCounter + ".1")
                }
            }
        }
    }
}
