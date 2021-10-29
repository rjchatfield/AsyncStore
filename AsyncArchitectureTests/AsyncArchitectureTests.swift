import XCTest
@testable import AsyncArchitecture

final class AsyncStoreTests: XCTestCase {

    func testExample() async throws {
        let store = await AsyncStore()
        let t = Task(priority: .high) {
            var time = 0
            while !Task.isCancelled {
                print(" ⏳ 0.\(time)s")
                try await Task.sleep(nanoseconds: 50_000_000)
                time += 5
            }
        }
        await store.send(.featureInitialised, "1")
        print("🧪😴")
        try await Task.sleep(nanoseconds: 600_000_000)
        print("🧪 🙀")
        await store.send(.buttonTapped, "2")
        print("🧪  😴")
        try await Task.sleep(nanoseconds: 100_000_000)
        print("🧪   🙀")
        await store.send(.buttonTapped, "3")
        print("🧪    😴")
        try await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
    }

}
