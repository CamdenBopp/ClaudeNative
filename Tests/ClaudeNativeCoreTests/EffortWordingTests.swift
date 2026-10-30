import Testing
@testable import ClaudeNativeCore

struct EffortWordingTests {
    @Test func cliLevelsReadAsWords() {
        #expect(EffortWording.title("xhigh") == "Extra High")
        #expect(EffortWording.title("max") == "Max")
        #expect(EffortWording.title("auto") == "Automatic")
    }
}
