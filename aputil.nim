import std/[os, strutils, osproc, times, terminal, exitprocs, sequtils]

when defined(posix):
    import std/posix
    if getuid() == 0:
        quit("ID 10 T Error: Running as root.", 1)

when defined(windows):
    quit("ID 10 T Error: Team Penguin only", 1)

proc isSafeRelativePath(path: string): bool =
    if path.len == 0 or isAbsolute(path):
        return false

    if path[0] == '\\' or ':' in path:
        return false

    for part in path.split({'/', '\\'}):
        if part == ".." or part == ".":
            return false

    return true

proc isValidName(name: string): bool =
    if name.len == 0:
        return false
    for ch in name:
        if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
            return false
    return true

proc readConfig(): seq[string] =
    for line in readFile("install.cfg").splitLines():
        if line.strip().len > 0:
            result.add(line.strip())
    if result.len < 3 or (result.len - 1) mod 2 != 0:
        quit("install.cfg must start with an app name, followed by action/argument line pairs", 1)
    if not isValidName(result[0]):
        quit("Invalid app name: use only letters, numbers, - and _", 1)

let aputilDirectory = getHomeDir() / ".local" / "opt" / "aputil"
let lockPath = getHomeDir() / ".local" / "opt" / "aputil.lock"

var cleanupPath = ""
var lockHeld = false

addExitProc(proc() {.noconv.} =
    try:
        if cleanupPath.len > 0 and dirExists(cleanupPath):
            removeDir(cleanupPath)
        if lockHeld:
            removeDir(lockPath)
    except OSError:
        discard
)

proc acquireLock() =
    createDir(parentDir(lockPath))
    for _ in 1 .. 3:
        if not existsOrCreateDir(lockPath):
            writeFile(lockPath / "pid", $getCurrentProcessId())
            lockHeld = true
            if dirExists(aputilDirectory):
                for kind, path in walkDir(aputilDirectory):
                    if kind == pcDir and extractFilename(path).startsWith(".staging-"):
                        removeDir(path)
            return

        sleep(300)
        var alive = true
        try:
            alive = kill(Pid(parseInt(readFile(lockPath / "pid").strip())), 0) == 0 or osLastError().int32 == EPERM
        except CatchableError:
            alive = false

        if alive:
            quit("Another aputil is running (lock: " & lockPath & ")", 1)

        removeDir(lockPath)

    quit("Could not acquire lock: " & lockPath, 1)

if paramCount() < 1:
    echo "Invalid number of arguments"
    echo "Usage: aputil <command> [arguments]"
    quit(1)

let command = paramStr(1)

if command == "install":
    if paramCount() != 2:
        quit("Usage: aputil install <directory containing install.cfg>", 1)

    if aputilDirectory notin getEnv("PATH").split(PathSep):
        echo aputilDirectory & " is not in PATH"

    try:
        setCurrentDir(absolutePath(paramStr(2)))
        acquireLock()
        cleanupPath = aputilDirectory / (".staging-" & $getCurrentProcessId() & "-" & $int(epochTime()))

        let installconfig = readConfig()
        let appName = installconfig[0]
        let appPath = aputilDirectory / appName
        let stagingAppPath = cleanupPath / appName

        if symlinkExists(appPath) or fileExists(appPath):
            quit("The name '" & appName & "' is already used by a link or file in " & aputilDirectory, 1)

        if dirExists(appPath):
            quit("Already installed. Use upgrade.", 1)

        if dirExists(appPath & ".old"):
            quit("Leftover backup from an interrupted upgrade at " & appPath & ".old. Delete it if you do not need it.", 1)

        for i in countup(1, installconfig.high, 2):
            if installconfig[i] == "dependency":
                let depName = installconfig[i + 1]
                if not isSafeRelativePath(depName) or not dirExists(aputilDirectory / depName):
                    quit("Dependency " & depName & " required.", 1)

        echo "Staging install for " & appName & "..."
        createDir(stagingAppPath)
        putEnv("APUTIL_APP_DIR", stagingAppPath)

        var newLinks: seq[tuple[executable: string, linkName: string]] = @[]

        for i in countup(1, installconfig.high, 2):
            let action = installconfig[i]
            let argumentLine = installconfig[i + 1]

            if action == "createDir":
                if not isSafeRelativePath(argumentLine):
                    quit("Invalid directory path: " & argumentLine, 1)

                if argumentLine.split({'/', '\\'})[0] == "installed_links.txt":
                    quit("installed_links.txt is reserved", 1)

                echo "Creating directory " & argumentLine
                createDir(stagingAppPath / argumentLine)

            else:
                let arguments = argumentLine.splitWhitespace()

                if action == "move-to-directory" or action == "copy-to-directory":
                    if arguments.len != 2:
                        quit(action & " requires: source destination", 1)

                    let source = arguments[0]
                    let relativeDestination = arguments[1]

                    if not isSafeRelativePath(source):
                        quit("Invalid source path: " & source, 1)

                    if not isSafeRelativePath(relativeDestination):
                        quit("Invalid destination path: " & relativeDestination, 1)

                    if relativeDestination.split({'/', '\\'})[0] == "installed_links.txt":
                        quit("installed_links.txt is reserved", 1)

                    let destination = stagingAppPath / relativeDestination
                    createDir(parentDir(destination))

                    if action == "move-to-directory":
                        echo "Moving " & source & " to " & relativeDestination
                        moveFile(source, destination)
                    else:
                        echo "Copying " & source & " to " & relativeDestination
                        copyFile(source, destination)

                elif action == "permission":
                    if arguments.len != 2:
                        quit("permission requires: mode path", 1)

                    let mode = arguments[0]
                    let relativePath = arguments[1]

                    if not isSafeRelativePath(relativePath):
                        quit("Invalid permission path: " & relativePath, 1)

                    if mode.len < 3 or mode.len > 4:
                        quit("Invalid permission mode: " & mode, 1)

                    for ch in mode:
                        if ch notin {'0'..'7'}:
                            quit("Invalid permission mode: " & mode, 1)

                    echo "Setting permissions for " & relativePath
                    if execShellCmd("chmod " & quoteShell(mode) & " " & quoteShell(stagingAppPath / relativePath)) != 0:
                        quit("Could not set permissions for " & relativePath, 1)

                elif action == "createSymlink":
                    if arguments.len != 2:
                        quit("createSymlink requires: executable-path link-name", 1)

                    let relativeExecutable = arguments[0]
                    let linkName = arguments[1]

                    if not isSafeRelativePath(relativeExecutable):
                        quit("Invalid executable path: " & relativeExecutable, 1)

                    if not isValidName(linkName):
                        quit("Invalid symlink name: use only letters, numbers, - and _", 1)

                    if linkName == appName:
                        quit("Symlink name cannot match the app name: " & linkName, 1)

                    if not fileExists(stagingAppPath / relativeExecutable):
                        quit("Executable not found in staged build: " & relativeExecutable, 1)

                    newLinks.add((relativeExecutable, linkName))

                elif action == "command":
                    if not isatty(stdin):
                        quit("Commands need an interactive terminal to confirm", 1)

                    var approved = false
                    while true:
                        stdout.write("Run command? [" & argumentLine & "] [y/N]: ")
                        let input = strip(readLine(stdin)).toLowerAscii()

                        if input == "y" or input == "yes":
                            approved = true
                            break
                        elif input == "" or input == "n" or input == "no":
                            break
                        else:
                            echo "Please type 'y' or 'n'."

                    if not approved:
                        quit("Installation aborted by user.", 1)

                    echo "Running command..."
                    if execShellCmd(argumentLine) != 0:
                        quit("Command failed", 1)

                elif action == "dependency":
                    discard

                else:
                    quit("Unknown action: " & action, 1)

        for linkInfo in newLinks:
            let linkPath = aputilDirectory / linkInfo.linkName
            if symlinkExists(linkPath) or fileExists(linkPath) or dirExists(linkPath):
                quit("Something already exists at " & linkPath, 1)

        echo "Build successful. Installing..."

        try:
            createDir(aputilDirectory)
            moveDir(stagingAppPath, appPath)

            var trackerContent = ""
            for linkInfo in newLinks:
                createSymlink(appPath / linkInfo.executable, aputilDirectory / linkInfo.linkName)
                echo "Created symlink " & linkInfo.linkName
                trackerContent.add(linkInfo.linkName & "\n")

            writeFile(appPath / "installed_links.txt", trackerContent)

        except CatchableError as error:
            for linkInfo in newLinks:
                let linkPath = aputilDirectory / linkInfo.linkName
                if symlinkExists(linkPath) and expandSymlink(linkPath).startsWith(appPath / ""):
                    removeFile(linkPath)
            if not dirExists(stagingAppPath):
                removeDir(appPath)
            quit("Install failed and was rolled back: " & error.msg, 1)

        echo "Successfully installed " & appName & "!"

    except CatchableError as error:
        quit("Installation failed: " & error.msg, 1)

elif command == "uninstall":
    if paramCount() != 2:
        quit("Usage: aputil uninstall <app-name>", 1)

    let appName = paramStr(2).strip()

    if not isValidName(appName):
        quit("Invalid app name: use only letters, numbers, - and _", 1)

    acquireLock()

    let appPath = aputilDirectory / appName

    if not dirExists(appPath):
        quit("App not found: " & appName, 1)

    if fileExists(appPath / "installed_links.txt"):
        echo "Removing tracked symlinks for " & appName & "..."
        for linkName in readFile(appPath / "installed_links.txt").splitLines():
            if isValidName(linkName):
                let symlinkPath = aputilDirectory / linkName
                if symlinkExists(symlinkPath) and expandSymlink(symlinkPath).startsWith(appPath / ""):
                    echo "Removing symlink: " & symlinkPath
                    removeFile(symlinkPath)

    echo "Removing app directory: " & appPath
    removeDir(appPath)
    echo "Successfully uninstalled " & appName

elif command == "upgrade":
    if paramCount() != 2:
        quit("Usage: aputil upgrade <directory containing install.cfg>", 1)

    try:
        setCurrentDir(absolutePath(paramStr(2)))
        acquireLock()
        cleanupPath = aputilDirectory / (".staging-" & $getCurrentProcessId() & "-" & $int(epochTime()))

        let installconfig = readConfig()
        let appName = installconfig[0]
        let liveAppPath = aputilDirectory / appName
        let stagingAppPath = cleanupPath / appName
        let backupPath = liveAppPath & ".old"

        if symlinkExists(liveAppPath) or not dirExists(liveAppPath):
            quit("Cannot upgrade: App '" & appName & "' is not installed. Use 'install' instead.", 1)

        if dirExists(backupPath):
            quit("Leftover backup from an interrupted upgrade at " & backupPath & ". Restore it by deleting " & liveAppPath & " and renaming the .old folder, or delete the .old folder if the app is fine.", 1)

        for i in countup(1, installconfig.high, 2):
            if installconfig[i] == "dependency":
                let depName = installconfig[i + 1]
                if not isSafeRelativePath(depName) or not dirExists(aputilDirectory / depName):
                    quit("Dependency " & depName & " required.", 1)

        echo "Staging upgrade for " & appName & "..."
        createDir(stagingAppPath)
        putEnv("APUTIL_APP_DIR", stagingAppPath)

        var newLinks: seq[tuple[executable: string, linkName: string]] = @[]

        for i in countup(1, installconfig.high, 2):
            let action = installconfig[i]
            let argumentLine = installconfig[i + 1]

            if action == "createDir":
                if not isSafeRelativePath(argumentLine):
                    quit("Invalid directory path: " & argumentLine, 1)

                if argumentLine.split({'/', '\\'})[0] == "installed_links.txt":
                    quit("installed_links.txt is reserved", 1)

                createDir(stagingAppPath / argumentLine)

            else:
                let arguments = argumentLine.splitWhitespace()

                if action == "move-to-directory" or action == "copy-to-directory":
                    if arguments.len != 2:
                        quit(action & " requires: source destination", 1)

                    let source = arguments[0]
                    let relativeDestination = arguments[1]

                    if not isSafeRelativePath(source) or not isSafeRelativePath(relativeDestination):
                        quit("Invalid path in " & action, 1)

                    if relativeDestination.split({'/', '\\'})[0] == "installed_links.txt":
                        quit("installed_links.txt is reserved", 1)

                    let destination = stagingAppPath / relativeDestination
                    createDir(parentDir(destination))

                    if action == "move-to-directory":
                        moveFile(source, destination)
                    else:
                        copyFile(source, destination)

                elif action == "permission":
                    if arguments.len != 2:
                        quit("permission requires: mode path", 1)

                    let mode = arguments[0]
                    let relativePath = arguments[1]

                    if not isSafeRelativePath(relativePath):
                        quit("Invalid permission path", 1)

                    if mode.len < 3 or mode.len > 4:
                        quit("Invalid permission mode: " & mode, 1)

                    for ch in mode:
                        if ch notin {'0'..'7'}:
                            quit("Invalid permission mode: " & mode, 1)

                    if execShellCmd("chmod " & quoteShell(mode) & " " & quoteShell(stagingAppPath / relativePath)) != 0:
                        quit("Could not set permissions", 1)

                elif action == "createSymlink":
                    if arguments.len != 2:
                        quit("createSymlink requires: executable-path link-name", 1)

                    let relativeExecutable = arguments[0]
                    let linkName = arguments[1]

                    if not isSafeRelativePath(relativeExecutable):
                        quit("Invalid executable path: " & relativeExecutable, 1)

                    if not isValidName(linkName):
                        quit("Invalid symlink name: use only letters, numbers, - and _", 1)

                    if linkName == appName:
                        quit("Symlink name cannot match the app name: " & linkName, 1)

                    if not fileExists(stagingAppPath / relativeExecutable):
                        quit("Executable not found in staged build: " & relativeExecutable, 1)

                    newLinks.add((relativeExecutable, linkName))

                elif action == "command":
                    if not isatty(stdin):
                        quit("Commands need an interactive terminal to confirm", 1)

                    var approved = false
                    while true:
                        stdout.write("Run command? [" & argumentLine & "] [y/N]: ")
                        let input = strip(readLine(stdin)).toLowerAscii()

                        if input == "y" or input == "yes":
                            approved = true
                            break
                        elif input == "" or input == "n" or input == "no":
                            break
                        else:
                            echo "Please type 'y' or 'n'."

                    if not approved:
                        quit("Upgrade aborted by user.", 1)

                    if execShellCmd(argumentLine) != 0:
                        quit("Command failed during upgrade build", 1)

                elif action == "dependency":
                    discard

                else:
                    quit("Unknown action: " & action, 1)

        for linkInfo in newLinks:
            let linkPath = aputilDirectory / linkInfo.linkName
            if symlinkExists(linkPath):
                if not expandSymlink(linkPath).startsWith(liveAppPath / ""):
                    quit("Link " & linkInfo.linkName & " already exists and belongs to something else", 1)
            elif fileExists(linkPath) or dirExists(linkPath):
                quit("Something else already exists at " & linkPath, 1)

        var oldLinks: seq[tuple[linkName: string, target: string]] = @[]
        if fileExists(liveAppPath / "installed_links.txt"):
            for oldLink in readFile(liveAppPath / "installed_links.txt").splitLines():
                if isValidName(oldLink) and symlinkExists(aputilDirectory / oldLink):
                    oldLinks.add((oldLink, expandSymlink(aputilDirectory / oldLink)))

        echo "Build successful. Performing swap..."

        try:
            moveDir(liveAppPath, backupPath)
            moveDir(stagingAppPath, liveAppPath)

            var trackerContent = ""
            for linkInfo in newLinks:
                let linkPath = aputilDirectory / linkInfo.linkName
                if symlinkExists(linkPath):
                    removeFile(linkPath)
                createSymlink(liveAppPath / linkInfo.executable, linkPath)
                trackerContent.add(linkInfo.linkName & "\n")

            writeFile(liveAppPath / "installed_links.txt", trackerContent)

        except CatchableError as error:
            for linkInfo in newLinks:
                let linkPath = aputilDirectory / linkInfo.linkName
                if symlinkExists(linkPath) and expandSymlink(linkPath).startsWith(liveAppPath / ""):
                    removeFile(linkPath)
            if not dirExists(stagingAppPath):
                removeDir(liveAppPath)
            if dirExists(backupPath):
                moveDir(backupPath, liveAppPath)
                for old in oldLinks:
                    if not symlinkExists(aputilDirectory / old.linkName):
                        createSymlink(old.target, aputilDirectory / old.linkName)
            quit("Upgrade failed and was rolled back: " & error.msg, 1)

        for old in oldLinks:
            let linkPath = aputilDirectory / old.linkName
            if not newLinks.anyIt(it.linkName == old.linkName) and symlinkExists(linkPath) and expandSymlink(linkPath).startsWith(liveAppPath / ""):
                removeFile(linkPath)

        removeDir(backupPath)

        echo "Successfully upgraded " & appName & "!"

    except CatchableError as error:
        quit("Upgrade failed: " & error.msg, 1)

elif command == "list-packages":
    if not dirExists(aputilDirectory):
        echo "No packages installed."
        quit(0)
    for kind, path in walkDir(aputilDirectory):
        let name = extractFilename(path)
        if kind == pcDir and not name.endsWith(".old") and not name.startsWith("."):
            echo name

elif command == "info":
    if paramCount() != 2:
        quit("Usage: aputil info <directory containing install.cfg>", 1)

    try:
        setCurrentDir(absolutePath(paramStr(2)))

        let installconfig = readConfig()

        echo "=== Package Info: " & installconfig[0] & " ==="
        echo "Source Directory: " & getCurrentDir()
        echo ""
        echo "Planned Actions:"

        for i in countup(1, installconfig.high, 2):
            let action = installconfig[i]
            let argumentLine = installconfig[i + 1]
            let args = argumentLine.splitWhitespace()

            if action == "createDir":
                echo "  [Directory] Create: " & argumentLine
            elif action == "move-to-directory" and args.len == 2:
                echo "  [Move]      Source: " & args[0] & " -> Target: " & args[1]
            elif action == "copy-to-directory" and args.len == 2:
                echo "  [Copy]      Source: " & args[0] & " -> Target: " & args[1]
            elif action == "permission" and args.len == 2:
                echo "  [Perm]      Mode: " & args[0] & " on path: " & args[1]
            elif action == "createSymlink" and args.len == 2:
                echo "  [Symlink]   Binary: " & args[0] & " -> Link Name: " & args[1]
            elif action == "command":
                echo "  [Command]   Shell: " & argumentLine
            elif action == "dependency":
                echo "  [Dependency] Requires: " & argumentLine

    except CatchableError as error:
        quit("Failed to read package info: " & error.msg, 1)

else:
    quit("Unknown command: " & command & ". Usage: aputil <install|uninstall|upgrade|list-packages|info>", 1)