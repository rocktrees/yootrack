import Foundation
import Darwin

public enum InspectionStatus: String, Sendable { case verified, restricted, exited, replaced }

public struct ProcessTreeNode: Identifiable, Sendable {
    public var process: ProcessUsage
    public var depth: Int
    public var children: [ProcessIdentity]
    public var id: ProcessIdentity { process.id }
    public init(process: ProcessUsage, depth: Int, children: [ProcessIdentity] = []) {
        self.process = process; self.depth = depth; self.children = children
    }
}

public struct ProjectHint: Hashable, Sendable, Identifiable {
    public var name: String
    public var root: String
    public var id: String { root }
    public init(name: String, root: String) { self.name = name; self.root = root }
}

public struct ProjectSnapshot: Identifiable, Sendable {
    public var name: String
    public var root: String
    public var direct: String
    public var subtree: String
    public var launchedBy: String?
    public var id: String { root }
    public var digestLine: String {
        var line = "Project \(name) (\(root)): \(direct)"
        if let launchedBy { line += ". Kicked off by \(launchedBy)" }
        return line + ". " + subtree
    }
    public init(name: String, root: String, direct: String, subtree: String, launchedBy: String?) {
        self.name = name; self.root = root; self.direct = direct; self.subtree = subtree; self.launchedBy = launchedBy
    }
}

public struct ProcessContext: Sendable {
    public var status: InspectionStatus = .verified
    public var capturedAt = Date()
    public var identity: ProcessIdentity
    public var role: String
    public var arguments: [String]?
    public var workingDirectory: String?
    public var parents: [ProcessReading]
    public var responsible: ProcessReading?
    public var responsibleArguments: [String]?
    public var openPaths: [String]
    public var issues: [String]
    public init(status: InspectionStatus = .verified, capturedAt: Date = Date(), identity: ProcessIdentity, role: String, arguments: [String]?, workingDirectory: String?, parents: [ProcessReading], responsible: ProcessReading? = nil, responsibleArguments: [String]? = nil, openPaths: [String] = [], issues: [String]) {
        self.status = status; self.capturedAt = capturedAt; self.identity = identity; self.role = role
        self.arguments = arguments; self.workingDirectory = workingDirectory; self.parents = parents
        self.responsible = responsible; self.responsibleArguments = responsibleArguments; self.openPaths = openPaths; self.issues = issues
    }
    /// Arguments are filtered before entering this object. Environment values are never included.
    public var evidence: String {
        var lines = ["Role: " + role]
        if let arguments { lines.append("Filtered launch arguments: " + arguments.joined(separator: " ")) }
        if let workingDirectory { lines.append("Working directory: " + workingDirectory) }
        if let responsible {
            let cmd = responsibleArguments?.joined(separator: " ") ?? responsible.path
            lines.append("Kicked off by (responsible process): \(responsible.name) (PID \(responsible.identity.pid)) — \(cmd)")
        }
        if !parents.isEmpty { lines.append("Current parent chain: " + parents.map { "\($0.name) (PID \($0.identity.pid))" }.joined(separator: " ← ")) }
        if !openPaths.isEmpty { lines.append("Active files / directories: " + openPaths.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

public enum ProcessInspector {
    public static func inspect(_ reading: ProcessReading) -> ProcessContext? {
        let observed = NativeSampler.readProcess(pid: reading.identity.pid)
        let signalResult = observed == nil ? kill(reading.identity.pid, 0) : 0
        let signalError = errno
        let status = inspectionStatus(expected: reading.identity, observed: observed?.identity, signalResult: signalResult, signalError: signalError)
        guard status != .exited && status != .replaced else { return nil }
        guard let current = observed else {
            return ProcessContext(status: .restricted, identity: reading.identity, role: role(name: reading.name, path: reading.path), arguments: nil, workingDirectory: nil, parents: [], issues: ["macOS restricts local inspection of this process. The name, executable, owner and parent PID above come from the monitoring sample; its current identity, arguments and working directory could not be verified locally."])
        }
        var issues: [String] = []
        let raw = arguments(pid: reading.identity.pid)
        if raw == nil { issues.append("Launch arguments are unavailable for this process.") }
        var vnode = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let count = proc_pidinfo(reading.identity.pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size)
        let directory: String? = count == size ? withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        } : nil
        if directory == nil { issues.append("Working directory is unavailable.") }
        var parents: [ProcessReading] = [], child = current
        var seen: Set<Int32> = [current.identity.pid]
        var responsible: ProcessReading?
        var responsibleArgs: [String]?
        if let respPID = responsiblePID(for: reading.identity.pid), respPID > 1, respPID != reading.identity.pid,
           let respProc = NativeSampler.readProcess(pid: respPID), respProc.identity.start <= current.identity.start {
            responsible = respProc
            responsibleArgs = arguments(pid: respPID).map(filteredArguments)
        }
        for _ in 0..<8 {
            var nextParent: ProcessReading?
            if child.parentPID > 1, !seen.contains(child.parentPID),
               let parent = NativeSampler.readProcess(pid: child.parentPID), parent.identity.start <= child.identity.start {
                nextParent = parent
            } else if let resp = responsiblePID(for: child.identity.pid), resp > 1, !seen.contains(resp),
                      let parent = NativeSampler.readProcess(pid: resp), parent.identity.start <= child.identity.start {
                nextParent = parent
            }
            guard let parent = nextParent else { break }
            parents.append(parent); seen.insert(parent.identity.pid); child = parent
        }
        let open = openFilePaths(pid: reading.identity.pid)
        guard NativeSampler.readProcess(pid: reading.identity.pid)?.identity == reading.identity else { return nil }
        let computedRole = role(name: reading.name, path: reading.path, arguments: raw ?? [], responsible: responsible, openPaths: open)
        return ProcessContext(identity: reading.identity, role: computedRole, arguments: raw.map(filteredArguments), workingDirectory: directory?.isEmpty == false ? directory : nil, parents: parents, responsible: responsible, responsibleArguments: responsibleArgs, openPaths: open, issues: issues)
    }
    public static func inspectionStatus(expected: ProcessIdentity, observed: ProcessIdentity?, signalResult: Int32, signalError: Int32) -> InspectionStatus {
        if let observed { return observed == expected ? .verified : .replaced }
        if signalResult == 0 || signalError == EPERM { return .restricted }
        return signalError == ESRCH ? .exited : .restricted
    }
    public static func summaryFacts(_ contexts: [ProcessContext]) -> String {
        let groups = Dictionary(grouping: contexts) { context in
            "Working directory: " + (context.workingDirectory ?? "Unavailable") + "\nCurrent parent chain: " + (context.parents.isEmpty ? "Unavailable" : context.parents.map(\.name).joined(separator: " ← "))
        }
        return "\(contexts.count) process(es) inspected; \(contexts.filter { $0.status == .restricted }.count) have restricted local inspection.\n" + groups.keys.sorted().map { "\(groups[$0]!.count) process(es)\n" + $0 }.joined(separator: "\n\n") + "\nParent chains show current ancestry, not a proven original launcher. Restricted processes use monitoring metadata; missing launch details do not mean they exited."
    }
    /// Walks live processes downward from `roots`, verifying start times so reused PIDs cannot create false child edges.
    /// Also links XPC services whose macOS `responsiblePID` points at a parent in `roots`.
    public static func descendants(of roots: [ProcessUsage], in allProcesses: [ProcessUsage], maxDepth: Int = 6) -> [ProcessTreeNode] {
        let rootIDs = Set(roots.map(\.id))
        let nonRoots = allProcesses.filter { !rootIDs.contains($0.id) }
        var byParent: [Int32: [ProcessUsage]] = [:]
        for proc in nonRoots {
            byParent[proc.reading.parentPID, default: []].append(proc)
            if proc.reading.parentPID <= 1, let resp = responsiblePID(for: proc.id.pid), resp != proc.id.pid {
                byParent[resp, default: []].append(proc)
            }
        }
        var visited = rootIDs
        var result: [ProcessTreeNode] = []
        func sortedChildren(of parent: ProcessUsage) -> [ProcessUsage] {
            var unique: [ProcessIdentity: ProcessUsage] = [:]
            for candidate in byParent[parent.id.pid] ?? [] where candidate.id.start >= parent.id.start && !visited.contains(candidate.id) {
                unique[candidate.id] = candidate
            }
            return unique.values.sorted { ($0.processorWatts ?? -1, $0.cpuPercent ?? -1, Double($0.reading.memoryBytes ?? 0)) > ($1.processorWatts ?? -1, $1.cpuPercent ?? -1, Double($1.reading.memoryBytes ?? 0)) }
        }
        func walk(_ parent: ProcessUsage, depth: Int) {
            guard depth <= maxDepth else { return }
            let direct = sortedChildren(of: parent)
            for child in direct { visited.insert(child.id) }
            for child in direct {
                let grand = (byParent[child.id.pid] ?? []).filter { $0.id.start >= child.id.start && !visited.contains($0.id) }.map(\.id)
                result.append(ProcessTreeNode(process: child, depth: depth, children: grand))
                walk(child, depth: depth + 1)
            }
        }
        for root in roots { walk(root, depth: 1) }
        return result
    }
    public static func usageDigest(title: String, targets: [ProcessUsage], contexts: [ProcessContext], allProcesses: [ProcessUsage]) -> String {
        let contextByID = Dictionary(contexts.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        let tree = descendants(of: targets, in: allProcesses)
        let combined = targets + tree.map(\.process)
        let snapshots = projectSnapshots(targets: targets, contexts: contexts, allProcesses: allProcesses)
        var lines: [String] = []
        lines.append(contentsOf: snapshots.map(\.digestLine))
        if targets.count == 1, let target = targets.first {
            let ctx = contextByID[target.id]
            let roleText = ServiceDescriptions.guide(for: target.reading)?.purpose ?? ctx?.role ?? role(name: target.reading.name, path: target.reading.path)
            lines.append("Process: \(target.reading.name) (PID \(target.id.pid)) — \(roleText)")
            lines.append("Executable: \(target.reading.path.isEmpty ? "Unavailable" : target.reading.path)")
            if let resp = ctx?.responsible {
                let cmd = ctx?.responsibleArguments?.joined(separator: " ") ?? resp.path
                lines.append("Kicked off by: \(resp.name) (PID \(resp.identity.pid)) — \(cmd)")
            }
            if let parents = ctx?.parents, !parents.isEmpty {
                lines.append("Launcher chain: " + parents.reversed().map { "\($0.name) (PID \($0.identity.pid))" }.joined(separator: " → ") + " → \(target.reading.name)")
            }
            if let cwd = ctx?.workingDirectory, cwd != "/" { lines.append("Working directory: \(cwd)") }
            else if let cwd = ctx?.workingDirectory { lines.append("Working directory: \(cwd)") }
            if let args = ctx?.arguments, args.count > 1 { lines.append("Command: \(args.joined(separator: " "))") }
            if let open = ctx?.openPaths, !open.isEmpty {
                lines.append("Active files & folders: \(open.prefix(6).joined(separator: ", "))")
            }
            lines.append("Direct usage: \(formatUsage([target]))")
        } else {
            let roles = Dictionary(grouping: targets, by: { contextByID[$0.id]?.role ?? role(name: $0.reading.name, path: $0.reading.path) })
                .map { "\($0.value.count)× \($0.key)" }.sorted().joined(separator: ", ")
            lines.append("Group: \(title) (\(targets.count) processes: \(roles))")
            if let path = targets.compactMap(\.bundlePath).first ?? targets.first?.reading.path, !path.isEmpty { lines.append("Executable location: \(path)") }
            let launchers = Array(Set(contexts.compactMap { ctx -> String? in
                guard let r = ctx.responsible else { return nil }
                return "\(r.name) (PID \(r.identity.pid))"
            })).sorted()
            if !launchers.isEmpty { lines.append("Kicked off by: \(launchers.joined(separator: ", "))") }
            let cwds = Array(Set(contexts.compactMap(\.workingDirectory).filter { $0 != "/" })).sorted()
            if !cwds.isEmpty { lines.append("Working directories: \(cwds.prefix(3).joined(separator: ", "))") }
            let open = Array(Set(contexts.flatMap(\.openPaths))).sorted()
            if !open.isEmpty { lines.append("Active files & folders: \(open.prefix(6).joined(separator: ", "))") }
            lines.append("Group usage: \(formatUsage(targets))")
            if let top = targets.max(by: { ($0.processorWatts ?? $0.cpuPercent ?? 0) < ($1.processorWatts ?? $1.cpuPercent ?? 0) }) {
                lines.append("Top process: \(top.reading.name) (PID \(top.id.pid)) at \(formatUsage([top]))")
            }
        }
        if snapshots.isEmpty {
            if !tree.isEmpty {
                let topChildren = tree.prefix(5).map { "\($0.process.reading.name) (PID \($0.process.id.pid), \(formatUsage([$0.process])))" }.joined(separator: "; ")
                lines.append("Head of \(tree.count) child process(es): \(topChildren)")
                lines.append("Subtree total (including children): \(formatUsage(combined))")
            } else {
                lines.append("Child processes: none currently running under this selection")
            }
        } else if snapshots.count > 1 {
            lines.append("Combined selection total (not one project): \(formatUsage(combined))")
        }
        return lines.joined(separator: "\n")
    }
    /// KERN_PROCARGS2 contains argc, executable, argv, then environment. Stop at argc.
    public static func decodeArguments(_ data: Data) -> [String]? {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        guard let executableEnd = data[cursor...].firstIndex(of: 0) else { return nil }
        cursor = executableEnd + 1
        while cursor < data.count && data[cursor] == 0 { cursor += 1 }
        var values: [String] = []
        for _ in 0..<argc {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0),
                  let value = String(data: data[cursor..<end], encoding: .utf8) else { return nil }
            values.append(value); cursor = end + 1
        }
        return values
    }
    private static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 2 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        data.count = size
        return decodeArguments(data)
    }
    private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleSymbol: ResponsiblePIDFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsiblePIDFn.self)
    }()
    public static func responsiblePID(for pid: Int32) -> Int32? {
        guard pid > 0, let fn = responsibleSymbol else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }
    /// Walks up from a working directory or script path to the nearest git checkout. Falls back to the project folder name when there is no `.git`.
    public static func project(startingAt start: String) -> ProjectHint? {
        var url = URL(fileURLWithPath: start).standardizedFileURL
        if !url.pathExtension.isEmpty { url.deleteLastPathComponent() }
        var fallback: ProjectHint?
        let generic: Set<String> = ["src", "sources", "lib", "bin", "dist", "build", "node_modules", "versions", "share", "tmp", "var", "packages", "scripts"]
        for _ in 0..<12 {
            if isProjectStop(url.path) { break }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return ProjectHint(name: url.lastPathComponent, root: url.path)
            }
            let name = url.lastPathComponent
            if fallback == nil, !name.isEmpty, !generic.contains(name.lowercased()) {
                fallback = ProjectHint(name: name, root: url.path)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return fallback
    }
    public static func projects(in contexts: [ProcessContext]) -> [ProjectHint] {
        var seen = Set<String>()
        var result: [ProjectHint] = []
        for context in contexts {
            var starts: [String] = []
            if let cwd = context.workingDirectory, cwd != "/" { starts.append(cwd) }
            for arg in context.arguments?.dropFirst() ?? [] where !arg.hasPrefix("-") && arg != "[omitted]" {
                if arg.hasPrefix("/") { starts.append(arg) }
                else if let cwd = context.workingDirectory, scripts.contains(URL(fileURLWithPath: arg).pathExtension.lowercased()) {
                    starts.append(URL(fileURLWithPath: cwd).appendingPathComponent(arg).path)
                }
            }
            for start in starts {
                guard let hint = project(startingAt: start), seen.insert(hint.root).inserted else { continue }
                result.append(hint)
                if result.count == 4 { break }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func formatUsage(_ items: [ProcessUsage]) -> String {
        let watts = items.compactMap(\.processorWatts).reduce(0, +)
        let cpu = items.compactMap(\.cpuPercent).reduce(0, +)
        let mem = items.compactMap { $0.reading.memoryBytes }.reduce(0, +)
        let gpu = items.compactMap { $0.reading.gpuMillisecondsPerSecond }.reduce(0, +) / 10
        var parts = [String(format: "%.2f W processor power", watts), String(format: "%.1f%% CPU", cpu)]
        let net = items.compactMap { $0.reading.networkReceivedBytesPerSecond }.reduce(0, +) + items.compactMap { $0.reading.networkSentBytesPerSecond }.reduce(0, +)
        if mem > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: mem), countStyle: .memory) + " memory") }
        if gpu >= 0.1 { parts.append(String(format: "%.1f%% GPU", gpu)) }
        if net >= 1 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(min(net, Double(Int64.max / 2))), countStyle: .binary) + "/s network") }
        return parts.joined(separator: ", ")
    }
    /// One row per git project, with that project's own processes and the children hanging off them.
    public static func projectSnapshots(targets: [ProcessUsage], contexts: [ProcessContext], allProcesses: [ProcessUsage]) -> [ProjectSnapshot] {
        let byID = Dictionary(contexts.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [String: (hint: ProjectHint, processes: [ProcessUsage], launchers: [String])] = [:]
        for target in targets {
            guard let context = byID[target.id], let hint = primaryProject(context) else { continue }
            var group = groups[hint.root] ?? (hint, [], [])
            group.processes.append(target)
            if let responsible = context.responsible {
                let label = "\(responsible.name) (PID \(responsible.identity.pid))"
                if !group.launchers.contains(label) { group.launchers.append(label) }
            }
            groups[hint.root] = group
        }
        return groups.values.map { group in
            let names = group.processes.map { "\($0.reading.name) (PID \($0.id.pid))" }.joined(separator: ", ")
            let kids = descendants(of: group.processes, in: allProcesses).map(\.process)
            let subtree = kids.isEmpty ? "Subtree: no child processes" : "Subtree including \(kids.count) child process(es): \(formatUsage(group.processes + kids))"
            return ProjectSnapshot(name: group.hint.name, root: group.hint.root, direct: "\(names) at \(formatUsage(group.processes))", subtree: subtree, launchedBy: group.launchers.isEmpty ? nil : group.launchers.joined(separator: ", "))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func primaryProject(_ context: ProcessContext) -> ProjectHint? {
        if let cwd = context.workingDirectory, cwd != "/", let hint = project(startingAt: cwd) { return hint }
        return projects(in: [context]).first
    }
    private static func isProjectStop(_ path: String) -> Bool {
        if path == "/" || path == "/Users" { return true }
        if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path { return true }
        let exact = ["/usr", "/bin", "/sbin", "/opt", "/System", "/Applications", "/tmp", "/Library"]
        let blocked = ["/usr/", "/bin/", "/sbin/", "/opt/", "/System/", "/Applications/", "/tmp/", "/private/tmp/", "/private/var/db/"]
        if exact.contains(path) || blocked.contains(where: { path.hasPrefix($0) }) { return true }
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains("Library") || parts.contains(".local") || parts.contains(".cursor")
    }
    /// Reads open vnode file paths for `pid` to reveal VM disks, sockets, or workspace directories when cwd is `/`.
    public static func openFilePaths(pid: Int32, limit: Int = 8) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard actual > 0 else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var results: [String] = []
        var seen: Set<String> = ["/", home]
        for fd in fds.prefix(Int(actual) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let path = withUnsafePointer(to: &vnode.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !path.isEmpty, !seen.contains(path),
                  !path.hasPrefix("/dev/"), !path.hasPrefix("/System/"), !path.hasPrefix("/usr/"),
                  !path.hasPrefix("/private/var/db/"), !path.hasPrefix("/Library/Preferences/Logging"),
                  !path.hasSuffix(".dylib"), !path.hasSuffix(".icns"), !path.hasSuffix(".car") else { continue }
            seen.insert(path)
            results.append(path)
            if results.count >= limit { break }
        }
        return results
    }
    private static let valueFlags: Set<String> = ["--type", "--utility-sub-type", "--renderer-client-id", "--service-sandbox-type", "--port", "--host", "--config", "-C", "--pidfile", "--socket", "--guestagent", "--inotify-dir", "--inotify-runtime", "--listen", "--listen-qemu", "--subnet", "-p"]
    private static let secretFlags: Set<String> = ["-c", "--eval", "--password", "--token", "--api-key", "--secret", "--authorization", "--header", "-h", "--cookie", "--user", "-u", "-e"]
    private static let scripts: Set<String> = ["py", "js", "mjs", "cjs", "ts", "sh", "rb", "pl", "json", "yaml", "yml", "toml", "swift", "db", "sqlite"]
    private static func safeText(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
    }
    private static func looksSafeToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 180, !token.contains("://"), !token.contains("="), !token.contains("\n") else { return false }
        let lower = token.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("eyj") || lower.hasPrefix("ghp_") || lower.hasPrefix("xox") || lower.contains("secret") || lower.contains("token") || lower.contains("password") { return false }
        if scripts.contains(URL(fileURLWithPath: token).pathExtension.lowercased()) { return true }
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") {
            return token.range(of: #"^[A-Za-z0-9_./ -]+$"#, options: .regularExpression) != nil
        }
        let looksOpaqueSecret = token.count > 28 && token.rangeOfCharacter(from: .decimalDigits) != nil && token.rangeOfCharacter(from: .letters) != nil && !token.contains("/") && !token.contains(".")
        return token.range(of: #"^[A-Za-z0-9_.:/-]{1,48}$"#, options: .regularExpression) != nil && !looksOpaqueSecret
    }
    public static func filteredArguments(_ arguments: [String]) -> [String] {
        guard let executable = arguments.first else { return [] }
        var result = [safeText(executable)], index = 1
        while index < arguments.count && result.count < 40 {
            let argument = arguments[index]
            let pieces = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let flag = pieces.first ?? argument
            if secretFlags.contains(flag.lowercased()) {
                result.append("[omitted]")
                if pieces.count == 1, index + 1 < arguments.count { index += 1 }
            } else if valueFlags.contains(flag) {
                if pieces.count == 2 { result.append(flag + "=" + (looksSafeToken(pieces[1]) ? safeText(pieces[1]) : "[omitted]")) }
                else if index + 1 < arguments.count { result.append(flag); index += 1; result.append(looksSafeToken(arguments[index]) ? safeText(arguments[index]) : "[omitted]") }
            } else if argument == "-m", index + 1 < arguments.count {
                result.append(argument); index += 1
                let module = arguments[index]
                result.append(module.range(of: #"^[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil ? module : "[omitted]")
            } else if argument.hasPrefix("-") {
                if pieces.count == 1 && argument.range(of: #"^-[A-Za-z0-9-]{1,32}$"#, options: .regularExpression) != nil { result.append(argument) }
                else { result.append("[omitted]") }
            } else if looksSafeToken(argument) {
                result.append(safeText(argument))
            } else {
                result.append("[omitted]")
            }
            index += 1
        }
        return result
    }
    public static func role(name: String, path: String, arguments: [String] = [], responsible: ProcessReading? = nil, openPaths: [String] = []) -> String {
        func option(_ flag: String) -> String? {
            if let match = arguments.first(where: { $0.hasPrefix(flag + "=") }) { return String(match.dropFirst(flag.count + 1)) }
            if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) { return arguments[index + 1] }
            return nil
        }
        switch option("--type") {
        case "renderer": return "Web renderer · tab/frame identity unavailable"
        case "gpu-process": return "Browser graphics / GPU process"
        case "utility":
            switch option("--utility-sub-type") {
            case "network.mojom.NetworkService": return "Browser network service"
            case "audio.mojom.AudioService": return "Browser audio service"
            case "storage.mojom.StorageService": return "Browser storage service"
            default: return "Browser utility process"
            }
        case "crashpad-handler": return "Browser crash reporting"
        default: break
        }
        let lower = name.lowercased()
        if lower.contains("virtualization.virtualmachine") {
            let vmHint: String? = openPaths.contains(where: { $0.contains(".colima") }) ? "Colima / Lima Linux VM" :
                openPaths.contains(where: { $0.contains(".lima") }) ? "Lima Linux VM" :
                openPaths.contains(where: { $0.lowercased().contains("orbstack") }) ? "OrbStack VM" :
                openPaths.contains(where: { $0.lowercased().contains("docker") }) ? "Docker VM" : nil
            if let vmHint, let responsible { return "\(vmHint) · kicked off by \(responsible.name) (PID \(responsible.identity.pid))" }
            if let vmHint { return vmHint }
            if let responsible { return "Linux / macOS Virtual Machine · kicked off by \(responsible.name) (PID \(responsible.identity.pid))" }
            return "Linux / macOS Virtual Machine (Apple Virtualization)"
        }
        if lower.contains("python"), let module = option("-m"), module.range(of: #"^[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil { return "Python module · " + safeText(module) }
        if lower.contains("python") || lower == "node" || lower == "ruby" || lower == "bash" || lower == "zsh" {
            if let script = filteredArguments(arguments).dropFirst().first(where: { scripts.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                return "Script · " + URL(fileURLWithPath: script).lastPathComponent
            }
            return "Interpreter · " + name
        }
        if lower.contains("helper (renderer)") { return "Web renderer · tab/frame identity unavailable" }
        if lower.contains("helper (gpu)") { return "Browser graphics / GPU process" }
        if lower.contains("helper") { return "App helper · inspect launch context" }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") {
            if let responsible { return "macOS XPC service · kicked off by \(responsible.name) (PID \(responsible.identity.pid))" }
            return "macOS service · " + name
        }
        if path.contains(".app/Contents/MacOS/") { return "Application process · " + name }
        return "Executable · " + name
    }
}
