import Foundation
import Security

@objc public protocol CollectorProtocol {
    func sample(interval: Double, reply: @escaping (Data?, String?) -> Void)
    func stop(reply: @escaping () -> Void)
}

public enum CollectorSecurity {
    public static func requirement(for executable: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(executable as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw NSError(domain: "PowerWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "The installed executable's signature is invalid."]) }
        var information: CFDictionary?
        let result = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard result == errSecSuccess, let info = information as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data,
              info[kSecCodeInfoIdentifier as String] as? String == identifier else {
            throw NSError(domain: "PowerWatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "The installed collector has an unexpected identity."])
        }
        return "identifier \"\(identifier)\" and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    }
    public static func accepts(uid: UInt32, configuredUID: UInt32, activeClient: Bool) -> Bool { uid == configuredUID && !activeClient }
}
