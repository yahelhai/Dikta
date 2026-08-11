import DiktaCore

// Thin shell over DiktaCore: with a recognised subcommand this runs headless and
// exits, otherwise it launches the menu-bar app. The dispatch table itself lives
// in DiktaCore so it is reachable from the tests.
let arguments = CommandLine.arguments

// >= 2 so a bare subcommand prints its usage instead of launching the app.
if arguments.count >= 2,
   let code = runSubcommand(arguments[1], Array(arguments.dropFirst(2))) {
    cleanExit(code)
}

runMenuBarApp()
