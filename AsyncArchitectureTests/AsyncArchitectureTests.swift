import XCTest
@testable import AsyncArchitecture

final class AsyncStoreTests: XCTestCase {

    @MainActor
    func testExample() async throws {
        weak var _store: AsyncStore?
        var store: AsyncStore! = AsyncStore()
        _store = store
        let t = Task(priority: .high) {
            var time = 0
            while !Task.isCancelled {
                print(" ⏳ 0.\(time)s")
                try await Task.sleep(nanoseconds: 50_000_000)
                time += 5
            }
        }
        print("\n\n\n")
        store.send(.featureInitialised, "1")
        print("🧪😴")
        try await Task.sleep(nanoseconds: 600_000_000)
        print("🧪 🙀")
        store.send(.buttonTapped, "2")
        print("🧪  😴")
        try await Task.sleep(nanoseconds: 100_000_000)
        print("🧪   🙀")
        store.send(.buttonTapped, "3")
        store.send(.dismissed, "4")
        print("🧪    😴")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(_store?.state.history, [
            .featureInitialised,
            .subscriptionTick,
            .subscriptionTick,
            .subscriptionTick,
            .fetchComplete,
            .subscriptionTick,
            .subscriptionTick,
            .subscriptionTick,
            .buttonTapped,
            .subscriptionTick,
            .buttonTapped,
            .dismissed,
            .subscriptionTick,
            .subscriptionTick,
            .fetchComplete,
            .subscriptionTick
        ])
        store = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store)
        XCTAssertNil(_store, "Something is retaining `self`?")
        t.cancel()
        print("\n\n\n")
    }

}
