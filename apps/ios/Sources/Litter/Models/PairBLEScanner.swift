#if !targetEnvironment(macCatalyst)
import CoreBluetooth
import Foundation

/// iPhone-side scanner for the Mac pair beacon advertised by
/// `PairBLEAdvertiser`. Pure transport — emits raw `(peripheralId, localName,
/// rssi)` samples. Smoothing, threshold debouncing, and pair-trigger logic
/// live in `NearbyMacPairing` so the scanner stays UI-agnostic.
@MainActor
final class PairBLEScanner: NSObject {
    typealias SampleHandler = (UUID, String?, Int) -> Void

    private var central: CBCentralManager?
    private var delegateBridge: PairBLEScannerDelegate?
    private var pendingStart = false
    private var sampleHandler: SampleHandler?

    func start(onSample: @escaping SampleHandler) {
        guard central == nil else { return }
        sampleHandler = onSample
        pendingStart = true
        let bridge = PairBLEScannerDelegate(owner: self)
        delegateBridge = bridge
        central = CBCentralManager(
            delegate: bridge,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        central?.stopScan()
        central = nil
        delegateBridge = nil
        pendingStart = false
        sampleHandler = nil
    }

    fileprivate func managerStateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            guard pendingStart, let central else { return }
            pendingStart = false
            // AllowDuplicates so RSSI streams continuously instead of one
            // event per peripheral. Without it the proximity gate can't
            // tell "phone moved closer" from "phone hasn't moved."
            central.scanForPeripherals(
                withServices: [PairBLE.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            LLog.info("pair", "BLE scan started", fields: ["service": PairBLE.serviceUUID.uuidString])
        case .unauthorized:
            LLog.warn("pair", "BLE central unauthorized — proximity gating unavailable")
        case .unsupported:
            LLog.info("pair", "BLE central unsupported on this device")
        case .poweredOff:
            LLog.info("pair", "BLE central poweredOff")
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    fileprivate func didDiscover(peripheralId: UUID, localName: String?, rssi: Int) {
        sampleHandler?(peripheralId, localName, rssi)
    }
}

private final class PairBLEScannerDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private weak var owner: PairBLEScanner?

    init(owner: PairBLEScanner) {
        self.owner = owner
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            owner?.managerStateChanged(state)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        Task { @MainActor in
            owner?.didDiscover(peripheralId: id, localName: name, rssi: rssi)
        }
    }
}
#endif
