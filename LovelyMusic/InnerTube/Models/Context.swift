import Foundation

struct InnerTubeContext: Codable {
    let client: Client

    struct Client: Codable {
        let clientName: String
        let clientVersion: String
        let osVersion: String?
        let gl: String
        let hl: String
        let visitorData: String?
        let deviceMake: String?
        let deviceModel: String?
        let platform: String?
        let userAgent: String?

        init(
            clientName: String,
            clientVersion: String,
            osVersion: String? = nil,
            gl: String,
            hl: String,
            visitorData: String? = nil,
            deviceMake: String? = nil,
            deviceModel: String? = nil,
            platform: String? = nil,
            userAgent: String? = nil
        ) {
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.osVersion = osVersion
            self.gl = gl
            self.hl = hl
            self.visitorData = visitorData
            self.deviceMake = deviceMake
            self.deviceModel = deviceModel
            self.platform = platform
            self.userAgent = userAgent
        }
    }

    struct ThirdParty: Codable {
        let embedUrl: String
    }
}
