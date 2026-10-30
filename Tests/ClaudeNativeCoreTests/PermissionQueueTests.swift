import Testing
@testable import ClaudeNativeCore

struct PermissionQueueTests {
    let write = PermissionRequest(requestID: "a", toolName: "Write", input: .object([:]))
    let bash = PermissionRequest(requestID: "b", toolName: "Bash", input: .object([:]))

    @Test func aSecondRequestWaitsBehindTheFirst() {
        var queue = PermissionQueue()
        queue.enqueue(write)
        queue.enqueue(bash)
        #expect(queue.current == write)
        queue.resolve("a")
        #expect(queue.current == bash)
        queue.resolve("b")
        #expect(queue.current == nil)
    }

    @Test func aRepeatedRequestIsShownOnce() {
        var queue = PermissionQueue()
        queue.enqueue(write)
        queue.enqueue(write)
        #expect(queue.waiting.count == 1)
    }

    @Test func clearingDropsEverything() {
        var queue = PermissionQueue()
        queue.enqueue(write)
        queue.enqueue(bash)
        queue.clear()
        #expect(queue.current == nil)
    }
}
