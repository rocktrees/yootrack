import Foundation
import Darwin

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "process"
let iterations = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 300
let native = NativeSampler(), gpu = GPUSampler(), engine = MeasurementEngine()
var paths: [ProcessIdentity: String] = [:], names: [ProcessIdentity: String] = [:]
func processes() -> [ProcessReading] {
    let count = proc_listallpids(nil, 0)
    var pids = [Int32](repeating: 0, count: max(64, Int(count) + 128))
    let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    var readings: [ProcessReading] = [], nextPaths: [ProcessIdentity: String] = [:], nextNames: [ProcessIdentity: String] = [:]
    for pid in pids.prefix(max(0, min(Int(actual), pids.count))) where pid > 0 {
        guard let reading = NativeSampler.readProcess(pid: pid, cachedPaths: paths, cachedNames: names) else { continue }
        readings.append(reading); nextPaths[reading.identity] = reading.path
        if !reading.path.isEmpty { nextNames[reading.identity] = reading.name }
    }
    paths = nextPaths; names = nextNames
    return readings
}
func cpuTime() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}
var fixedProcesses = processes()
var count = 0, readable = 0, gpuReadable = 0, encodedBytes = 0
var checksum: UInt64 = 0
func pass() {
    switch mode {
    case "process":
        let p = processes(); count = p.count; readable = p.filter { $0.cpuNanoseconds != nil }.count
        checksum &+= p.reduce(0) { $0 &+ UInt64($1.identity.pid) &+ ($1.memoryBytes ?? 0) }
    case "gpu":
        let (reading, rates) = gpu.sample(processes: fixedProcesses, uptime: ProcessInfo.processInfo.systemUptime)
        count = fixedProcesses.count; gpuReadable = reading.measuredProcesses
        checksum &+= UInt64(rates.count)
    case "pipeline":
        let sample = native.sample(interval: 15)
        let usage = engine.ingest(sample, expectedInterval: 15)
        let groups = AppUsage.grouped(usage.processes)
        let data = try! JSONEncoder().encode(sample)
        count = sample.processes.count; readable = sample.processes.filter { $0.cpuNanoseconds != nil }.count
        gpuReadable = sample.gpu?.measuredProcesses ?? 0; encodedBytes = data.count
        checksum &+= UInt64(groups.count + data.count)
    default: fatalError("Unknown benchmark mode")
    }
}
for _ in 0..<10 { autoreleasepool { pass() } }
let cpuStart = cpuTime(), wallStart = ProcessInfo.processInfo.systemUptime
for _ in 0..<iterations { autoreleasepool { pass() } }
let wall = ProcessInfo.processInfo.systemUptime - wallStart, cpu = cpuTime() - cpuStart
var usage = rusage_info_v6()
let read = withUnsafeMutablePointer(to: &usage) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
let result: [String: Any] = ["language":"Swift", "mode":mode, "iterations":iterations, "wall_ms_per_pass":wall * 1000 / Double(iterations), "cpu_ms_per_pass":cpu * 1000 / Double(iterations), "processes":count, "readable_processes":readable, "gpu_processes":gpuReadable, "encoded_bytes":encodedBytes, "footprint_mib":read == 0 ? Double(usage.ri_phys_footprint)/1048576 : -1, "checksum":String(checksum)]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
