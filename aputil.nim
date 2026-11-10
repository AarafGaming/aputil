import std/[os, strutils, osproc]

when defined(posix):
    import std/posix
    if getuid() == 0:
        quit("ID 10 T Error: Running as root., 1)

proc isSafeRelativePath(path: string): bool =
    if path.len == 0 or isAbsolute(path):
        return false

    if path[0] == '\\' or ':' in path:
        return false

    for part in path.split({'/', '\\'}):
        if part == "..":
            return false

    return true

if paramCount() < 1:
    echo "Invalid number of arguments"
    echo "Usage: aputil <command> [arguments]"
    quit(1)

let command = paramStr(1)

if command == "install":
    if paramCount() != 2:
        quit("Usage: aputil install <directory containing install.cfg>", 1)

    let packageDirectory = absolutePath(paramStr(2))
    let aputilDirectory = getHomeDir() / ".local" / "opt" / "aputil"
    let pathEntries = getEnv("PATH").split(PathSep)

    if aputilDirectory notin pathEntries:
        echo aputilDirectory & " is not in PATH"

    try:
        setCurrentDir(packageDirectory)

        var installconfig: seq[string] = @[]
        for line in readFile("install.cfg").splitLines():
            let trimmed = line.strip()
            if trimmed.len > 0:
                installconfig.add(trimmed)

        if installconfig.len < 3 or (installconfig.len - 1) mod 2 != 0:
            quit("install.cfg must start with an app name, followed by action/argument line pairs", 1)

        let appName = installconfig[0].strip()

        if appName.len == 0:
            quit("App name cannot be empty", 1)

        for ch in appName:
            if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
                quit("Invalid app name: use only letters, numbers, - and _", 1)

        let appPath = aputilDirectory / appName
        createDir(appPath)

        for i in countup(1, installconfig.high, 2):
            let action = installconfig[i].strip()
            let argumentLine = installconfig[i + 1].strip()

            if action == "createDir":
                if not isSafeRelativePath(argumentLine):
                    quit("Invalid directory path: " & argumentLine, 1)

                let destination = appPath / argumentLine
                echo "Creating directory " & destination
                createDir(destination)

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

                    let destination = appPath / relativeDestination
                    let destinationDirectory = parentDir(destination)

                    if destinationDirectory != "":
                        createDir(destinationDirectory)

                    if action == "move-to-directory":
                        echo "Moving " & source & " to " & destination
                        moveFile(source, destination)
                    else:
                        echo "Copying " & source & " to " & destination
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

                    let destination = appPath / relativePath
                    echo "Setting permissions for " & destination

                    let result = execShellCmd(
                    "chmod " & quoteShell(mode) & " " & quoteShell(destination)
                    )

                    if result != 0:
                        quit("Could not set permissions for " & destination, 1)

                elif action == "createSymlink":
                    if arguments.len != 2:
                        quit("createSymlink requires: executable-path link-name", 1)

                    let relativeExecutable = arguments[0]
                    let linkName = arguments[1]

                    if not isSafeRelativePath(relativeExecutable):
                        quit("Invalid executable path: " & relativeExecutable, 1)

                    if linkName.len == 0 or '/' in linkName or '\\' in linkName or linkName.contains(".."):
                        quit("Invalid symlink name: " & linkName, 1)

                    for ch in linkName:
                        if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
                            quit("Invalid symlink name: use only letters, numbers, - and _", 1)

                    let executable = appPath / relativeExecutable
                    let linkPath = aputilDirectory / linkName

                    if not fileExists(executable):
                        quit("Executable not found: " & executable, 1)

                    createDir(aputilDirectory)
                    echo "Creating symlink " & linkPath & " -> " & executable
                    
                    if fileExists(linkPath) or dirExists(linkPath) or symlinkExists(linkPath):
                        removeFile(linkPath)

                    createSymlink(executable, linkPath)
                    let trackerFile = appPath / "installed_links.txt"
                    try:
                        let existingLinks = if fileExists(trackerFile): readFile(trackerFile) else: ""
                        writeFile(trackerFile, existingLinks & linkName & "\n")
                    except OSError:
                        discard

                elif action == "command":
                    var approved = false
                    while true:
                        stdout.write("Run command? [" & argumentLine & "] [y/N]: ")
                        let input = strip(readLine(stdin)).toLowerAscii()
                        if input == "y" or input == "yes":
                            approved = true
                            break
                        elif input == "" or input == "n" or input == "no":
                            approved = false
                            break
                        else:
                            echo "Please type 'y' or 'n'."

                    if approved:
                        echo "Running command..."
                        let result = execShellCmd(argumentLine)
                        if result != 0:
                            quit("Command failed with exit code: " & $result, 1)
                    else:
                        quit("Installation aborted by user.", 1)

    except OSError as error:
        quit("Installation failed: " & error.msg, 1)

elif command == "uninstall":
    if paramCount() != 2:
        quit("Usage: aputil uninstall <app-name>", 1)

    let aputilDirectory = getHomeDir() / ".local" / "opt" / "aputil"
    let appName = paramStr(2)
    let appPath = aputilDirectory / appName
    let trackerFile = appPath / "installed_links.txt"

    if not dirExists(appPath):
        quit("App not found: " & appName, 1)

    if fileExists(trackerFile):
        echo "Removing tracked symlinks for " & appName & "..."
        for linkName in readFile(trackerFile).splitLines():
            let trimmed = linkName.strip()
            if trimmed.len > 0:
                let symlinkPath = aputilDirectory / trimmed
                if fileExists(symlinkPath) or symlinkExists(symlinkPath):
                    echo "Removing symlink: " & symlinkPath
                    removeFile(symlinkPath)

    echo "Removing app directory: " & appPath
    removeDir(appPath)
    echo "Successfully uninstalled " & appName

elif command == "upgrade":
    if paramCount() != 2:
        quit("Usage: aputil upgrade <directory containing install.cfg>", 1)

    let packageDirectory = absolutePath(paramStr(2))
    let aputilDirectory = getHomeDir() / ".local" / "opt" / "aputil"
    let tempRoot = getHomeDir() / ".local" / "temp"

    try:
        setCurrentDir(packageDirectory)

        var installconfig: seq[string] = @[]
        for line in readFile("install.cfg").splitLines():
            let trimmed = line.strip()
            if trimmed.len > 0:
                installconfig.add(trimmed)
        if installconfig.len < 3 or (installconfig.len - 1) mod 2 != 0:
            quit("install.cfg must start with an app name, followed by action/argument line pairs", 1)

        let appName = installconfig[0].strip()
        if appName.len == 0:
            quit("App name cannot be empty", 1)

        let liveAppPath = aputilDirectory / appName
        let stagingAppPath = tempRoot / appName

        if not dirExists(liveAppPath):
            quit("Cannot upgrade: App '" & appName & "' is not installed. Use 'install' instead.", 1)

        echo "Staging upgrade for " & appName & "..."
        
        createDir(tempRoot)
        if dirExists(stagingAppPath):
            removeDir(stagingAppPath)
        createDir(stagingAppPath)

        var newLinks: seq[tuple[executable: string, linkName: string]] = @[]

        for i in countup(1, installconfig.high, 2):
            let action = installconfig[i].strip()
            let argumentLine = installconfig[i + 1].strip()

            if action == "createDir":
                if not isSafeRelativePath(argumentLine):
                    quit("Invalid directory path: " & argumentLine, 1)
                createDir(stagingAppPath / argumentLine)

            elif action == "move-to-directory" or action == "copy-to-directory":
                let arguments = argumentLine.splitWhitespace()
                if arguments.len != 2:
                    quit(action & " requires: source destination", 1)
                let source = arguments[0]
                let relativeDestination = arguments[1]

                if not isSafeRelativePath(source) or not isSafeRelativePath(relativeDestination):
                    quit("Invalid path in " & action, 1)

                let destination = stagingAppPath / relativeDestination
                let destDir = parentDir(destination)
                if destDir != "": createDir(destDir)

                if action == "move-to-directory":
                    moveFile(source, destination)
                else:
                    copyFile(source, destination)

            elif action == "permission":
                let arguments = argumentLine.splitWhitespace()
                if arguments.len != 2:
                    quit("permission requires: mode path", 1)
                let mode = arguments[0]
                let relativePath = arguments[1]

                if not isSafeRelativePath(relativePath):
                    quit("Invalid permission path", 1)

                let destination = stagingAppPath / relativePath
                let result = execShellCmd("chmod " & quoteShell(mode) & " " & quoteShell(destination))
                if result != 0:
                    quit("Could not set permissions", 1)

            elif action == "createSymlink":
                let arguments = argumentLine.splitWhitespace()
                if arguments.len != 2:
                    quit("createSymlink requires: executable-path link-name", 1)
                let relativeExecutable = arguments[0]
                let linkName = arguments[1]

                if not isSafeRelativePath(relativeExecutable) or linkName.len == 0 or '/' in linkName or '\\' in linkName or linkName.contains(".."):
                    quit("Invalid symlink configuration", 1)

                let executableInStaging = stagingAppPath / relativeExecutable
                if not fileExists(executableInStaging):
                    quit("Executable not found in staged build: " & executableInStaging, 1)

                newLinks.add((relativeExecutable, linkName))

            elif action == "command":
                let result = execShellCmd(argumentLine)
                if result != 0:
                    quit("Command failed during upgrade build", 1)

        echo "Build successful. Performing atomic swap..."

        let oldTrackerFile = liveAppPath / "installed_links.txt"
        if fileExists(oldTrackerFile):
            for oldLink in readFile(oldTrackerFile).splitLines():
                let trimmed = oldLink.strip()
                if trimmed.len > 0:
                    let linkPath = aputilDirectory / trimmed
                    if fileExists(linkPath) or symlinkExists(linkPath):
                        removeFile(linkPath)

        removeDir(liveAppPath)
        moveDir(stagingAppPath, liveAppPath)

        let newTrackerFile = liveAppPath / "installed_links.txt"
        var trackerContent = ""
        createDir(aputilDirectory)

        for linkInfo in newLinks:
            let finalExecutable = liveAppPath / linkInfo.executable
            let linkPath = aputilDirectory / linkInfo.linkName

            if fileExists(linkPath) or dirExists(linkPath) or symlinkExists(linkPath):
                removeFile(linkPath)

            createSymlink(finalExecutable, linkPath)
            trackerContent.add(linkInfo.linkName & "\n")

        writeFile(newTrackerFile, trackerContent)
        echo "Successfully upgraded " & appName & "!"

    except OSError as error:
        let stagingAppPath = tempRoot / paramStr(2)
        if dirExists(stagingAppPath):
            removeDir(stagingAppPath)
        quit("Upgrade failed: " & error.msg, 1)

elif command == "list-packages":
    let aputilDirectory = getHomeDir() / ".local" / "opt" / "aputil"
    setCurrentDir(aputilDirectory)
    for i in walkDirs("*"):
        echo i

elif command == "info":
    if paramCount() != 2:
        quit("Usage: aputil info <directory containing install.cfg>", 1)

    let packageDirectory = absolutePath(paramStr(2))

    try:
        setCurrentDir(packageDirectory)

        var installconfig: seq[string] = @[]
        for line in readFile("install.cfg").splitLines():
            let trimmed = line.strip()
            if trimmed.len > 0:
                installconfig.add(trimmed)
        if installconfig.len < 3 or (installconfig.len - 1) mod 2 != 0:
            quit("install.cfg must start with an app name, followed by action/argument line pairs", 1)

        let appName = installconfig[0].strip()
        if appName.len == 0:
            quit("App name cannot be empty", 1)

        echo "=== Package Info: " & appName & " ==="
        echo "Source Directory: " & packageDirectory
        echo ""
        echo "Planned Actions:"

        for i in countup(1, installconfig.high, 2):
            let action = installconfig[i].strip()
            let argumentLine = installconfig[i + 1].strip()

            if action == "createDir":
                echo "  [Directory] Create: " & argumentLine
            elif action == "move-to-directory":
                let args = argumentLine.splitWhitespace()
                if args.len == 2:
                    echo "  [Move]      Source: " & args[0] & " -> Target: " & args[1]
            elif action == "copy-to-directory":
                let args = argumentLine.splitWhitespace()
                if args.len == 2:
                    echo "  [Copy]      Source: " & args[0] & " -> Target: " & args[1]
            elif action == "permission":
                let args = argumentLine.splitWhitespace()
                if args.len == 2:
                    echo "  [Perm]      Mode: " & args[0] & " on path: " & args[1]
            elif action == "createSymlink":
                let args = argumentLine.splitWhitespace()
                if args.len == 2:
                    echo "  [Symlink]   Binary: " & args[0] & " -> Link Name: " & args[1]
            elif action == "command":
                echo "  [Command]   Shell: " & argumentLine

    except OSError as error:
        quit("Failed to read package info: " & error.msg, 1)

else:
    quit("Unknown command: " & command & ". Usage: aputil <install|uninstall|upgrade|list-packages|info>", 1)