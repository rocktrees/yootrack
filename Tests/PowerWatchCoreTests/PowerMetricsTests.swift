import XCTest
import Security
@testable import PowerWatchCore

final class PowerMetricsTests: XCTestCase {
    func fixture() throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "plist", subdirectory: "Fixtures"))) }
    func testNULDelimitedChunkedFramesAndUnits() throws {
        let data = try fixture(); var stream = PowerMetricsDecoder()
        XCTAssertTrue(try stream.append(data.prefix(30)).isEmpty)
        var remainder = Data(data.dropFirst(30)); remainder.append(0); remainder.append(data); remainder.append(0)
        let result = try stream.append(remainder)
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result[0].cpuWatts!, 1.5, accuracy: 0.001)
        XCTAssertEqual(result[0].gpuWatts!, 0.25, accuracy: 0.001); XCTAssertEqual(result[0].neuralWatts!, 0.1, accuracy: 0.001)
        XCTAssertEqual(result[0].impactByPID, [123: 4.5])
    }
    func testEnergyFormatAndInvalidValues() throws {
        let fixture: [String: Any] = ["elapsed_ns": 5_000_000_000, "processor": ["cpu_energy": 5000], "gpu": ["gpu_energy": 1000], "ane": ["ane_power": 999, "invalid": true], "tasks": [["pid": 1, "energy_impact": -1], ["pid": 2, "energy_impact": 10, "invalid": true]]]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0)
        let reading = try PowerMetricsDecoder.decode(data)
        XCTAssertEqual(reading.cpuWatts, 1); XCTAssertEqual(reading.gpuWatts, 0.2); XCTAssertNil(reading.neuralWatts); XCTAssertTrue(reading.impactByPID.isEmpty)
    }
    func testCoalitionRowsAreFlattenedAndImpactUsesRateWithoutDoubleCounting() throws {
        let sample: [String: Any] = ["coalitions": [["id": 1000, "energy_impact_per_s": 99, "tasks": [["pid": 42, "energy_impact": 50, "energy_impact_per_s": 10]]]], "tasks": [["pid": 42, "energy_impact_per_s": 10]]]
        let reading = try PowerMetricsDecoder.decode(PropertyListSerialization.data(fromPropertyList: sample, format: .xml, options: 0))
        XCTAssertEqual(reading.impactByPID, [42: 10])
    }
    func testGPUAndNetworkRatesWithoutImpactAndUnavailableValues() throws {
        let fixture: [String: Any] = ["elapsed_ns": 5_000_000_000, "tasks": [
            ["pid": 42, "gputime_ms_per_s": 125.0, "gputime_ns": 999, "bytes_received_per_s": 4096, "bytes_sent_per_s": 0],
            ["pid": 43, "gputime_ns": 250_000_000, "bytes_received": 10000, "bytes_sent": 500],
            ["pid": 44, "gputime_ms_per_s": -1, "bytes_sent_per_s": -1],
            ["pid": 45, "gputime_ms_per_s": 100, "invalid": true]]]
        let value = try PowerMetricsDecoder.decode(PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0))
        XCTAssertEqual(value.gpuMillisecondsByPID, [42: 125, 43: 50])
        XCTAssertEqual(value.networkReceivedByPID, [42: 4096, 43: 2000])
        XCTAssertEqual(value.networkSentByPID, [42: 0, 43: 100])
        XCTAssertTrue(value.impactByPID.isEmpty)
        let missingDuration: [String: Any] = ["tasks": [["pid": 42, "gputime_ns": 10, "bytes_received": 200]]]
        let missing = try PowerMetricsDecoder.decode(PropertyListSerialization.data(fromPropertyList: missingDuration, format: .xml, options: 0))
        XCTAssertTrue(missing.gpuMillisecondsByPID!.isEmpty); XCTAssertTrue(missing.networkReceivedByPID!.isEmpty)
    }
    func testMalformedAndOversizedOutputAreRejected() {
        var decoder = PowerMetricsDecoder(); XCTAssertThrowsError(try decoder.append(Data("not a plist\0".utf8)))
        XCTAssertThrowsError(try decoder.append(Data(repeating: 32, count: 16 * 1024 * 1024)))
    }
    func testBytewiseFramesAndRecoveryAfterMalformedFrame() throws {
        let data = try fixture()
        var decoder = PowerMetricsDecoder()
        for byte in data { XCTAssertTrue(try decoder.append(Data([byte])).isEmpty) }
        XCTAssertEqual(try decoder.append(Data([0])).first?.cpuWatts, 1.5)
        var brokenThenValid = Data("invalid\0".utf8)
        brokenThenValid.append(data); brokenThenValid.append(0)
        XCTAssertThrowsError(try decoder.append(brokenThenValid))
        // A malformed frame must not discard a valid frame already buffered behind it.
        XCTAssertEqual(try decoder.append(Data()).first?.impactByPID, [123: 4.5])
        XCTAssertTrue(try decoder.append(data.prefix(20)).isEmpty)
        var tail = Data(data.dropFirst(20)); tail.append(0)
        XCTAssertEqual(try decoder.append(tail).count, 1)
    }
    func testHelperAuthorizationRules() {
        XCTAssertTrue(CollectorSecurity.accepts(uid: 501, configuredUID: 501, activeClient: false))
        XCTAssertFalse(CollectorSecurity.accepts(uid: 0, configuredUID: 501, activeClient: false))
        XCTAssertFalse(CollectorSecurity.accepts(uid: 501, configuredUID: 501, activeClient: true))
    }
    func testPinnedExecutableRequirementCompilesAndMatchesOnlyItsIdentity() throws {
        let executable = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("PowerWatchProbe")
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        let identifier = try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String)
        let rule = try CollectorSecurity.requirement(for: executable, identifier: identifier)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(rule as CFString, [], &requirement), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(code!, [], requirement), errSecSuccess)
        XCTAssertThrowsError(try CollectorSecurity.requirement(for: executable, identifier: "ai.powerwatch.app"))
    }
    func testMissingHardwareMetricsAreUnavailable() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["tasks": []], format: .xml, options: 0)
        let reading = try PowerMetricsDecoder.decode(data); XCTAssertNil(reading.cpuWatts); XCTAssertNil(reading.gpuWatts); XCTAssertNil(reading.neuralWatts)
    }
}
