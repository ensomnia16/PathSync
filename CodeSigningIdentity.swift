import Foundation

let pathSyncCodeSigningCertificateSHA1 = "C47BF244BCBD892D97951161EB00ABCA90E81918"

func pathSyncCodeSigningRequirement(_ identifier: String = "com.ensom.ResearchSync") -> String {
    "=identifier \"" + identifier + "\" and certificate leaf = H\"" + pathSyncCodeSigningCertificateSHA1 + "\""
}
