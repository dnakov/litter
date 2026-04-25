#if targetEnvironment(macCatalyst)
import CoreBluetooth
import Foundation

/// Mac-side BLE advertiser. Publishes `PairBLE.serviceUUID` plus a local-name
/// payload (`mac_id_short`) so iPhones running `PairBLEScanner` get an RSSI
/// proximity signal that doesn't depend on UWB hardware.
///
/// Scoped to Catalyst because the host side only ever runs on the direct-dist
/// Mac build alongside the local Codex runtime. iPhone equivalent is the
/// scanner in `PairBLEScanner.swift`.
@MainActor
final class PairBLEAdvertiser: NSObject {
    private var peripheralManager: CBPeripheralManager?
    private var delegateBridge: PairBLEAdvertiserDelegate?
    private var pendingStart = false
    private var advertisementData: [String: Any] = [:]

    /// Begin advertising. `localName` is appended to the BLE payload so the
    /// iPhone can correlate the BLE peer with the Bonjour pick (we use a short
    /// `litter:<mac_id_first8>` string — full UUIDs blow the 31-byte BLE
    /// advertisement budget).
    func start(localName: String) {
        guard peripheralManager == nil else { return }
        advertisementData = [
            CBAdvertisementDataServiceUUIDsKey: [PairBLE.serviceUUID],
            CBAdvertisementDataLocalNameKey: localName,
        ]
        pendingStart = true
        let bridge = PairBLEAdvertiserDelegate(owner: self)
        delegateBridge = bridge
        peripheralManager = CBPeripheralManager(
            delegate: bridge,
            queue: nil,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        peripheralManager?.stopAdvertising()
        peripheralManager = nil
        delegateBridge = nil
        pendingStart = false
        advertisementData.removeAll()
    }

    fileprivate func managerStateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            guard pendingStart, let pm = peripheralManager else { return }
            pendingStart = false
            pm.startAdvertising(advertisementData)
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
            LLog.info(
                "pair",
                "BLE advertising started",
                fields: ["local_name": name, "service": PairBLE.serviceUUID.uuidString]
            )
        case .unauthorized:
            LLog.warn("pair", "BLE peripheral unauthorized — Mac will not advertise pair beacon")
        case .unsupported:
            LLog.info("pair", "BLE peripheral unsupported on this Mac")
        case .poweredOff:
            LLog.info("pair", "BLE poweredOff — advertising paused")
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }
}

/// CoreBluetooth delegate methods are invoked on the queue passed to the
/// manager (we passed nil → main queue), but Swift's strict concurrency wants
/// the delegate marked non-isolated. Bounce into the @MainActor owner via Task.
private final class PairBLEAdvertiserDelegate: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private weak var owner: PairBLEAdvertiser?

    init(owner: PairBLEAdvertiser) {
        self.owner = owner
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        Task { @MainActor in
            owner?.managerStateChanged(state)
        }
    }
}
#endif
