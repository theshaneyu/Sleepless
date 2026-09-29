import Foundation
import Testing
@testable import SleeplessCore

@Suite struct URLCommandTests {
    @Test func offTurnsKeepAwakeOff() {
        #expect(URLCommand(URL(string: "sleepless://off")!) == .turnOff)
    }

    @Test(arguments: ["sleepless://on", "sleepless://", "other://off"])
    func nothingElseIsACommand(_ url: String) {
        #expect(URLCommand(URL(string: url)!) == nil)
    }
}
