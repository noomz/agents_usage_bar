import Foundation
import SwiftUI

/// Process entry. GUI launches become `AgentsUsageBarApp`; `aub` / known
/// subcommands skip Sparkle, notifications, and `NSApplication`.
@main
enum AUBMain {
    static func main() async {
        let args = CommandLine.arguments
        let exe = URL(fileURLWithPath: args[0]).lastPathComponent
        let rest = Array(args.dropFirst())
        let isCLI =
            exe == CLIInstaller.binaryName
            || rest.first == "--cli"
            || (rest.first.map(AUBCommand.isSubcommand) ?? false)
        if isCLI {
            let code = await AUBCommand.run(arguments: rest.filter { $0 != "--cli" })
            Foundation.exit(code)
        } else {
            AgentsUsageBarApp.main()
        }
    }
}
