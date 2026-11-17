import Foundation
import Security
import Network

/// Self-signed certificate so the receiver can be served over HTTPS
/// (browsers only enable WebCodecs / hardware H.264 in secure contexts).
enum TLSIdentity {
    static let pass = "macscreen"

    static func load(ips: [String], host: String) -> sec_identity_t? {
        let fm = FileManager.default
        let dir = NSHomeDirectory() + "/Library/Application Support/MacScreen"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p12 = dir + "/identity.p12", meta = dir + "/identity.sans"
        let sans = (["localhost", host, "127.0.0.1"] + ips).sorted().joined(separator: ",")
        let existing = try? String(contentsOfFile: meta, encoding: .utf8)
        if existing != sans || !fm.fileExists(atPath: p12) {
            guard generate(dir: dir, p12: p12, ips: ["127.0.0.1"] + ips, host: host) else { return nil }
            try? sans.write(toFile: meta, atomically: true, encoding: .utf8)
        }
        guard let data = fm.contents(atPath: p12) else { return nil }
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: pass] as CFDictionary, &items)
        guard st == errSecSuccess, let arr = items as? [[String: Any]],
              let any = arr.first?[kSecImportItemIdentity as String] else {
            log("PKCS12 import failed: \(st)"); return nil
        }
        return sec_identity_create(any as! SecIdentity)
    }

    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            log("openssl failed: \(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        return p.terminationStatus == 0
    }

    private static func generate(dir: String, p12: String, ips: [String], host: String) -> Bool {
        var cnf = """
        [req]
        distinguished_name=dn
        x509_extensions=v3
        prompt=no
        [dn]
        CN=MacScreen
        [v3]
        basicConstraints=CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=@alt
        [alt]
        DNS.1=localhost
        DNS.2=\(host)

        """
        for (i, ip) in ips.enumerated() { cnf += "IP.\(i + 1)=\(ip)\n" }
        let cnfPath = dir + "/openssl.cnf", key = dir + "/key.pem", crt = dir + "/cert.pem"
        do { try cnf.write(toFile: cnfPath, atomically: true, encoding: .utf8) } catch { return false }
        guard run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
                   "-days", "825", "-config", cnfPath]) else { return false }
        return run(["pkcs12", "-export", "-inkey", key, "-in", crt, "-out", p12, "-passout", "pass:" + pass])
    }
}
