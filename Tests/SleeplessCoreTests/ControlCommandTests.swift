import Testing
@testable import SleeplessCore

@Suite struct ControlCommandTests {
    @Test func repeatedOnAndOffDoNotRepeatTheSwitchAction() {
        #expect(ControlCommand.on.stateChange(current: true) == nil)
        #expect(ControlCommand.off.stateChange(current: false) == nil)
        #expect(ControlCommand.on.stateChange(current: false) == true)
        #expect(ControlCommand.off.stateChange(current: true) == false)
    }

    @Test(arguments: [true, false])
    func toggleAlwaysFlipsAndStatusNeverChangesTheSwitch(current: Bool) {
        #expect(ControlCommand.toggle.stateChange(current: current) == !current)
        #expect(ControlCommand.status.stateChange(current: current) == nil)
    }

    @Test(arguments: [["on", "off"], ["on", "--force"], ["--on"], ["ON"], ["unknown"]])
    func malformedCommandsAreRejectedBeforeLaunchingTheApp(arguments: [String]) {
        #expect(CLIInvocation(arguments: arguments) == nil)
    }

    @Test func parsesThePublicCommandsAndHelp() {
        for command in [ControlCommand.on, .off, .toggle, .status] {
            #expect(CLIInvocation(arguments: [command.rawValue]) == .command(command))
        }
        #expect(CLIInvocation(arguments: []) == .help)
        #expect(CLIInvocation(arguments: ["--help"]) == .help)
    }
}
