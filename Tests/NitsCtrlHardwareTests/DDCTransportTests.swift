import XCTest
@testable import NitsCtrlHardware

final class DDCTransportTests: XCTestCase {
    private struct Service: Identifiable, Equatable {
        let id: String
        let path: String
    }

    func testDiscoveryKeepsFirstServiceForDuplicateIdentity() {
        // A projector and a second output with the same placeholder-serial EDID.
        let services = [
            Service(id: "v00004ca3-p0000a70a-s01010101", path: "a"),
            Service(id: "v000010ac-p00004276-s4139354c", path: "b"),
            Service(id: "v00004ca3-p0000a70a-s01010101", path: "c"),
        ]

        XCTAssertEqual(DDCTransport.firstOfEachID(services), [services[0], services[1]])
    }
}
