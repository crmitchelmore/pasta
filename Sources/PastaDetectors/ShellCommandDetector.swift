import Foundation

public struct ShellCommandDetector {
    public struct Detection: Equatable {
        public let command: String
        public let executable: String
        public let confidence: Double
        
        public init(command: String, executable: String, confidence: Double) {
            self.command = command
            self.executable = executable
            self.confidence = confidence
        }
    }
    
    // Common shell commands and executables
    private static let commonCommands: Set<String> = [
        // File operations
        "ls", "cd", "pwd", "mkdir", "rmdir", "rm", "cp", "mv", "touch", "cat", "less", "more", "head", "tail",
        "find", "locate", "which", "whereis", "file", "stat", "chmod", "chown", "chgrp", "ln", "readlink",
        // Text processing
        "grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "gawk", "sort", "uniq", "wc", "cut", "tr", "diff", "patch",
        "jq", "yq", "xq",
        // System
        "sudo", "su", "ps", "top", "htop", "btop", "kill", "killall", "pkill", "bg", "fg", "jobs", "nohup", "screen", "tmux",
        "systemctl", "service", "launchctl", "defaults", "open", "pbcopy", "pbpaste",
        // Network
        "curl", "wget", "http", "httpie", "ssh", "scp", "sftp", "rsync", "ping", "netstat", "ss", "ifconfig", "ip", "nc", "netcat", "telnet",
        "dig", "nslookup", "host", "traceroute", "mtr", "nmap", "lsof",
        // Package managers
        "apt", "apt-get", "dpkg", "yum", "dnf", "rpm", "pacman", "brew", "port",
        "npm", "npx", "yarn", "pnpm", "bun", "deno",
        "pip", "pip3", "pipx", "pipenv", "poetry", "uv", "conda",
        "gem", "bundle", "bundler",
        "cargo", "rustup",
        "go", "gofmt",
        "composer",
        "pod", "carthage",
        "swift", "swiftc", "xcodebuild", "xcrun", "xcode-select",
        "mix", "hex", "rebar3",
        "stack", "cabal", "ghc",
        "dotnet", "nuget",
        "maven", "mvn", "gradle", "gradlew",
        // Version control
        "git", "gh", "hub", "svn", "hg", "fossil",
        // Containers/VMs/Cloud
        "docker", "docker-compose", "podman", "buildah", "skopeo",
        "kubectl", "k9s", "helm", "minikube", "kind",
        "vagrant", "packer",
        "terraform", "terragrunt", "pulumi", "cdktf",
        "aws", "gcloud", "az", "doctl", "flyctl", "vercel", "netlify", "heroku", "railway",
        // Build tools
        "make", "cmake", "ninja", "meson", "bazel", "buck",
        "ant", "sbt",
        "task", "just", "mise", "asdf",
        // Shells/scripting/runtimes
        "bash", "sh", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "python", "python3", "python2", "ipython",
        "node", "nodejs", "ts-node", "tsx",
        "ruby", "irb", "rails", "rake",
        "perl", "php", "lua", "r", "Rscript",
        "java", "javac", "jar", "kotlin", "kotlinc", "scala", "scalac",
        "erl", "elixir", "iex",
        "ghci", "runhaskell",
        // Editors/IDE
        "vim", "nvim", "vi", "nano", "emacs", "code", "subl", "atom", "idea", "webstorm", "pycharm",
        // Testing
        "jest", "vitest", "mocha", "pytest", "rspec", "phpunit", "go test",
        // Linting/formatting
        "eslint", "prettier", "black", "flake8", "pylint", "rubocop", "shellcheck", "hadolint",
        // Misc CLI tools
        "echo", "printf", "env", "export", "source", "alias", "unalias", "history", "man", "info", "tldr",
        "xargs", "tee", "time", "timeout", "watch", "cron", "crontab",
        "tar", "gzip", "gunzip", "bzip2", "xz", "zip", "unzip", "7z", "rar",
        "openssl", "base64", "md5", "sha256sum", "shasum",
        "date", "cal", "bc", "expr",
        "seq", "yes", "true", "false", "test", "sleep",
        "whoami", "id", "groups", "hostname", "uname",
        "df", "du", "free", "uptime", "w", "who", "last",
        "clear", "reset", "tput",
        "set", "unset", "export", "declare", "local", "readonly",
        "if", "then", "else", "fi", "for", "do", "done", "while", "until", "case", "esac",
        "ffmpeg", "ffprobe", "imagemagick", "convert", "magick",
        "fzf", "bat", "exa", "eza", "fd", "sd", "delta", "difft", "hyperfine", "tokei", "dust", "duf", "procs", "btm", "bandwhich", "grex",
    ]
    
    // Patterns that strongly indicate shell commands
    private static let shellPatterns: [(pattern: String, weight: Double)] = [
        (#"^\s*\$\s+"#, 0.95),              // Starts with $ prompt
        (#"^\s*>\s+"#, 0.8),                // Starts with > prompt
        (#"^#!"#, 0.99),                    // Shebang
        (#"\|\s*\w+"#, 0.9),                // Pipe to command
        (#"\s&&\s"#, 0.9),                  // && chaining
        (#"\s\|\|\s"#, 0.9),                // || chaining
        (#"\s*;\s*\w+"#, 0.8),              // ; chaining
        (#">\s*/dev/null"#, 0.95),          // Redirect to /dev/null
        (#"2>&1"#, 0.95),                   // Stderr redirect
        (#">\s*\S+"#, 0.7),                 // Output redirect
        (#"<\s*\S+"#, 0.7),                 // Input redirect
        (#"\$\([^)]+\)"#, 0.9),             // Command substitution $(...)
        (#"`[^`]+`"#, 0.85),                // Backtick command substitution
        (#"\$\{\w+[^}]*\}"#, 0.85),         // Variable expansion ${...}
        (#"\$[A-Z_][A-Z0-9_]*"#, 0.7),      // Env variable reference
    ]
    
    // Flag patterns with weights
    private static let flagPatterns: [(pattern: String, weight: Double)] = [
        (#"\s--[a-z][-a-z0-9]*"#, 0.6),     // Long flags --foo-bar
        (#"\s--[a-z][-a-z0-9]*="#, 0.7),    // Long flags with = --foo=bar
        (#"\s-[a-zA-Z]\s"#, 0.4),           // Short flag -x (with space after)
        (#"\s-[a-zA-Z]$"#, 0.4),            // Short flag at end -x
        (#"\s-[a-zA-Z][a-zA-Z]+"#, 0.5),    // Combined short flags -xvf
    ]
    
    public init() {}
    
    public func detect(in text: String) -> [Detection] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        // Skip if it looks like prose (many sentences with proper punctuation)
        let periodCount = trimmed.filter { $0 == "." }.count
        let wordCount = trimmed.split(separator: " ").count
        if periodCount > 2 && Double(periodCount) / Double(wordCount) > 0.1 {
            return []
        }
        
        // Skip if too long (shell commands are usually short, but allow for pipes)
        if trimmed.count > 1000 { return [] }
        
        // Check each line
        var detections: [Detection] = []
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") } // Skip empty and comment lines
        
        for line in lines {
            if let detection = detectLine(line) {
                detections.append(detection)
            }
        }
        
        // If we found commands in most non-empty lines, return them
        if !detections.isEmpty && Double(detections.count) / Double(max(lines.count, 1)) >= 0.5 {
            return detections
        }
        
        // Also check the whole text as a single command if no line-by-line detections
        if detections.isEmpty, let detection = detectLine(trimmed) {
            return [detection]
        }
        
        return detections
    }
    
    private func detectLine(_ line: String) -> Detection? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count >= 2 else { return nil }
        
        // Remove common prompts
        var command = trimmed
        if let range = command.range(of: #"^\s*[\$>%#]\s+"#, options: .regularExpression) {
            command = String(command[range.upperBound...])
        }
        // Also handle prompts like "user@host:~$"
        if let range = command.range(of: #"^[^$#%>]*[\$#%>]\s+"#, options: .regularExpression) {
            command = String(command[range.upperBound...])
        }
        
        // Get first word (the executable)
        let words = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let firstWord = words.first else { return nil }
        
        // Handle path prefixes like ./script or /usr/bin/env
        var executable = String(firstWord)
        if executable.contains("/") {
            executable = String(executable.split(separator: "/").last ?? Substring(executable))
        }
        executable = executable.lowercased()
        
        var confidence = 0.0
        
        // Check if it starts with a known command (high signal)
        if Self.commonCommands.contains(executable) {
            confidence += 0.65
        }
        
        // Check for shell patterns (accumulative)
        for (pattern, weight) in Self.shellPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                confidence += weight * 0.4  // Scale down so multiple patterns boost but don't overflow
            }
        }
        
        // Check for flag patterns (accumulative)
        var flagScore = 0.0
        for (pattern, weight) in Self.flagPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: command, options: [], range: NSRange(command.startIndex..., in: command)) != nil {
                flagScore += weight
            }
        }
        confidence += min(flagScore, 0.4)  // Cap flag contribution
        
        // Boost for typical shell command structure: word followed by args
        if words.count >= 2 {
            let hasArgs = command.contains(" -") || command.contains(" --") || command.range(of: #"\s\S+/\S+"#, options: .regularExpression) != nil
            if hasArgs {
                confidence += 0.15
            }
        }
        
        // Slight boost for commands with subcommands (git commit, docker run, npm install)
        if words.count >= 2, let secondWord = command.split(separator: " ").dropFirst().first {
            let subcommand = String(secondWord).lowercased()
            let commonSubcommands: Set<String> = [
                "install", "uninstall", "update", "upgrade", "add", "remove", "rm", "del", "delete",
                "init", "create", "new", "build", "run", "start", "stop", "restart", "test", "dev", "serve",
                "push", "pull", "fetch", "clone", "commit", "checkout", "branch", "merge", "rebase", "stash", "log", "diff", "status",
                "exec", "attach", "logs", "ps", "images", "volume", "network", "compose",
                "apply", "get", "describe", "delete", "create", "edit",
                "login", "logout", "whoami", "config", "set", "get", "list", "show", "info", "version", "help",
            ]
            if commonSubcommands.contains(subcommand) {
                confidence += 0.2
            }
        }
        
        // Cap confidence at 1.0
        confidence = min(confidence, 1.0)
        
        // Lower threshold for detection
        guard confidence >= 0.5 else { return nil }
        
        return Detection(command: command, executable: executable, confidence: confidence)
    }
}
