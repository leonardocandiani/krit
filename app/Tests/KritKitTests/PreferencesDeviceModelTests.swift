import XCTest
@testable import KritKit

@MainActor
final class PreferencesDeviceModelTests: XCTestCase {
    func testStartsWithoutHardwareDiscoveryAndPublishesAsyncCatalog() async {
        let catalog = PreferencesDeviceCatalog(
            microphones: [
                .systemDefault,
                PreferencesDeviceOption(id: "mic-1", name: "Studio Mic"),
            ],
            cameras: [
                .systemDefault,
                PreferencesDeviceOption(id: "cam-1", name: "Desk Camera"),
            ]
        )
        let model = PreferencesDeviceModel(loader: StubPreferencesDeviceLoader(catalog: catalog))

        XCTAssertEqual(model.microphones, [.systemDefault])
        XCTAssertEqual(model.cameras, [.systemDefault])

        await model.refresh()

        XCTAssertEqual(model.microphones, catalog.microphones)
        XCTAssertEqual(model.cameras, catalog.cameras)
    }
}
private struct StubPreferencesDeviceLoader: PreferencesDeviceLoading {
    let catalog: PreferencesDeviceCatalog

    func load() async -> PreferencesDeviceCatalog { catalog }
}
