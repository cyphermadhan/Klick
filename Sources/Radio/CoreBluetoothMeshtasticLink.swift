@preconcurrency import CoreBluetooth
import Foundation
import os

/// Real `MeshtasticLink` backed by CoreBluetooth.
///
/// Wire-level flow (Meshtastic BLE GATT):
///
///   1. Scan for peripherals advertising the service UUID.
///   2. On connect, discover the service + three characteristics:
///        - `ToRadio`   (write)            — we put protobuf frames here
///        - `FromRadio` (read)             — we read responses from here
///        - `FromNum`   (notify)           — fires when FromRadio has data
///   3. Subscribe to FromNum notifications. Each notification is a hint
///      that there's data to read from FromRadio. Drain FromRadio by
///      repeatedly reading until it returns empty.
///   4. To talk: write protobuf frames to ToRadio.
///
/// This matches the phone-side documentation at
/// https://meshtastic.org/docs/development/device/client-api/#ble
///
/// Phase 3b.2b ships the code paths; actual interop needs a
/// Meshtastic-compatible radio on the bench. The `ScanEntry` publisher
/// and pair flow are wired through to `RadioView` but can't be verified
/// in the simulator (CoreBluetooth central + BLE don't work there).
final class CoreBluetoothMeshtasticLink: NSObject, MeshtasticLink, @unchecked Sendable {
    // MARK: - Meshtastic GATT UUIDs

    /// Primary service. Advertised by every Meshtastic-compatible device.
    static let serviceUUID = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioUUID = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    /// Notify characteristic — when it fires, read FromRadio until empty.
    static let fromNumUUID = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    // MARK: - Scan results for the pair UI

    /// One discovery during an active scan. `rssi` lets the UI sort
    /// nearest-first.
    struct ScanEntry: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    /// Published list updates during scanning. `RadioView` observes this
    /// to populate its pair sheet. Emptied when a scan stops.
    var onScanResults: (@Sendable ([ScanEntry]) -> Void)?

    // MARK: - MeshtasticLink

    private(set) var isConnected: Bool = false
    var onFrame: (@Sendable (Data) -> Void)?
    var onConnectedChange: (@Sendable (Bool) -> Void)?

    // MARK: - Private state (main-queue only)

    private let queue = DispatchQueue(label: "klick.meshtastic.ble")
    private let log = Logger(subsystem: "world.madhans.klick", category: "BLE")
    private var central: CBCentralManager?
    /// Peripheral we're actively talking to, once discovered + connected.
    private var peripheral: CBPeripheral?
    /// Found during characteristic discovery, used for reads/writes.
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var fromNum: CBCharacteristic?
    /// Accumulated scan results while scanning. Map keyed by identifier
    /// so a peripheral appearing twice doesn't produce duplicate rows.
    private var scanResults: [UUID: ScanEntry] = [:]
    /// Identifier of the peripheral the user picked in the scan sheet.
    private var targetIdentifier: UUID?

    override init() {
        super.init()
        // Central is created lazily in `start()` — instantiating it
        // immediately would trigger the BLE permission prompt during
        // app launch instead of when the user opens RadioView.
    }

    // MARK: - Scan (pair flow)

    /// Start scanning. Filters to Meshtastic service-advertising devices
    /// so the user doesn't see irrelevant AirPods / heart-rate monitors.
    func startScan() {
        scanResults.removeAll()
        onScanResults?([])
        ensureCentral()
        scheduleScanIfPoweredOn()
    }

    /// Stop scanning. Leaves `scanResults` intact so the pair sheet can
    /// keep showing them while the user decides.
    func stopScan() {
        central?.stopScan()
    }

    /// Connect to a specific peripheral previously seen via scan.
    /// Transitions to `isConnected = true` once service + characteristic
    /// discovery completes.
    func connect(to identifier: UUID) {
        targetIdentifier = identifier
        guard let central else { return }
        // `retrievePeripherals(withIdentifiers:)` is the right API for
        // peers we've already seen — avoids re-scanning.
        guard let p = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            log.error("connect: peripheral \(identifier, privacy: .public) not retrievable")
            return
        }
        p.delegate = self
        peripheral = p
        central.connect(p, options: nil)
    }

    // MARK: - MeshtasticLink

    func start() {
        ensureCentral()
        // If we've already remembered a target from a previous session,
        // try to reconnect automatically.
        if let id = targetIdentifier { connect(to: id) }
    }

    func stop() {
        stopScan()
        if let p = peripheral, let central {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        toRadio = nil
        fromRadio = nil
        fromNum = nil
        setConnected(false)
    }

    @discardableResult
    func write(_ frame: Data) -> Bool {
        guard let peripheral, let toRadio, isConnected else { return false }
        // Write without response keeps throughput high; Meshtastic firmware
        // doesn't require ACKs at the GATT layer.
        peripheral.writeValue(frame, for: toRadio, type: .withoutResponse)
        return true
    }

    // MARK: - Private

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    private func scheduleScanIfPoweredOn() {
        // CBCentralManager state updates arrive asynchronously on the
        // delegate queue. If we're already .poweredOn, start immediately;
        // otherwise `centralManagerDidUpdateState` will kick this off.
        if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }

    private func setConnected(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        onConnectedChange?(connected)
    }

    /// Drain FromRadio until it returns an empty read — Meshtastic's
    /// documented protocol for the BLE transport.
    private func drainFromRadio() {
        guard let peripheral, let fromRadio else { return }
        peripheral.readValue(for: fromRadio)
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothMeshtasticLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scheduleScanIfPoweredOn()
        case .unauthorized, .poweredOff, .unsupported, .resetting, .unknown:
            setConnected(false)
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "RADIO"
        let entry = ScanEntry(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        scanResults[peripheral.identifier] = entry
        // Sort by RSSI (strongest first) so the pair sheet lists the
        // radio you're actually standing next to at the top.
        let sorted = scanResults.values.sorted { $0.rssi > $1.rssi }
        onScanResults?(sorted)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        setConnected(false)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        setConnected(false)
        log.error("didFailToConnect: \(String(describing: error))")
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothMeshtasticLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics(
                [Self.toRadioUUID, Self.fromRadioUUID, Self.fromNumUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case Self.toRadioUUID:   toRadio = c
            case Self.fromRadioUUID: fromRadio = c
            case Self.fromNumUUID:
                fromNum = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        // We're ready once all three are bound.
        if toRadio != nil, fromRadio != nil, fromNum != nil {
            setConnected(true)
            // Prime the pipeline — some firmwares have queued frames from
            // before the phone connected.
            drainFromRadio()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == Self.fromRadioUUID {
            if let value = characteristic.value, !value.isEmpty {
                onFrame?(value)
                // Keep reading — there may be more frames buffered.
                drainFromRadio()
            }
        } else if characteristic.uuid == Self.fromNumUUID {
            // FromNum notification: radio says "new data available".
            drainFromRadio()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.error("didWriteValueFor failed: \(String(describing: error))")
        }
    }
}
