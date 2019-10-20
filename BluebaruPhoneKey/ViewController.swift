//
//  ViewController.swift
//  BluebaruPhoneKey
//
//  Created by Cory Mayer on 10/19/19.
//  Copyright © 2019 Cory Mayer. All rights reserved.
//

import UIKit
import CoreBluetooth
import CryptoKit

class ViewController: UIViewController {
    let centralRestoreId = "bluebaru"
    let bluebaruDummySvcUUID = CBUUID(string: "963E")
    let bluebaryDummyCharUUID = CBUUID(string: "963E")
    let bluebaruUARTSvcUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    let bluebaruUARTRxCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    let bluebaruUARTTxCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
    var centralMgr: CBCentralManager!
    var bluebaruPeripheral: CBPeripheral?
    var uartRXCharacteristic: CBCharacteristic?
    var uartTXCharacteristic: CBCharacteristic?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        centralMgr = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey : centralRestoreId])
    }
    
    /**
    * This method sends the given test to the UART RX characteristic.
    * Depending on whether the characteristic has the Write Without Response or Write properties the behaviour is different.
    * In the latter case the Long Write may be used. To enable it you have to change the flag below in the code.
    * Otherwise, in both cases, texts longer than 20 (MTU) bytes (not characters) will be splitted into up-to 20-byte packets.
    * from https://github.com/NordicSemiconductor/IOS-nRF-Toolbox/blob/master/nRF%20Toolbox/BluetoothManager/BluetoothManager.swift
    *
    * - parameter aText: text to be sent to the peripheral using Nordic UART Service
    */
    func uartSend(text aText : String) {
        guard let uartRXCharacteristic = uartRXCharacteristic else {
            print("UART RX Characteristic not found")
            return
        }
        guard let bluetoothPeripheral = bluebaruPeripheral else {
            print("No peripheral")
            return
        }
        
        // Check what kind of Write Type is supported. By default it will try Without Response.
        // If the RX charactereisrtic have Write property the Write Request type will be used.
        var type: CBCharacteristicWriteType = .withoutResponse
        var MTU = bluetoothPeripheral.maximumWriteValueLength(for: .withoutResponse)
        if uartRXCharacteristic.properties.contains(.write) {
            type = .withResponse
            MTU = bluetoothPeripheral.maximumWriteValueLength(for: .withResponse)
        }
        
        // The following code will split the text into packets
        aText.split(by: MTU).forEach {
            send(text: $0, withType: type)
        }
    }
    
    /**
     * Sends the given text to the UART RX characteristic using the given write type.
     * This method does not split the text into parts. If the given write type is withResponse
     * and text is longer than 20-bytes the long write will be used.
     *
     * - parameters:
     *     - aText: text to be sent to the peripheral using Nordic UART Service
     *     - aType: write type to be used
     */
    func send(text aText : String, withType aType : CBCharacteristicWriteType) {
        guard uartRXCharacteristic != nil else {
            print("UART RX Characteristic not found")
            return
        }
        guard let bluetoothPeripheral = bluebaruPeripheral else {
            print("No peripheral")
            return
        }
        
        let typeAsString = aType == .withoutResponse ? ".withoutResponse" : ".withResponse"
        let data = aText.data(using: String.Encoding.utf8)!
        
        // Do some logging
        print("Writing to characteristic: \(uartRXCharacteristic!.uuid.uuidString)")
        print("peripheral.writeValue(\(aText)), for: \(uartRXCharacteristic!.uuid.uuidString), type: \(typeAsString))")
        bluetoothPeripheral.writeValue(data, for: uartRXCharacteristic!, type: aType)
        // The transmitted data is not available after the method returns. We have to log the text here.
        // The callback peripheral:didWriteValueForCharacteristic:error: is called only when the Write Request type was used,
        // but even if, the data is not available there.
        print("\"\(aText)\" sent")
    }
    
    func sendAuth() {
        uartSend(text: "Hello")
    }
}

extension ViewController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            print("central.state is .unknown")
        case .resetting:
            print("central.state is .resetting")
        case .unsupported:
            print("central.state is .unsupported")
        case .unauthorized:
            print("central.state is .unauthorized")
        case .poweredOff:
            print("central.state is .poweredOff")
        case .poweredOn:
            print("central.state is .poweredOn")
            centralMgr.scanForPeripherals(withServices: [bluebaruDummySvcUUID], options: nil)
        @unknown default:
            print("central.state is unknown")
        }
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        print("Restoring state")
        print(dict)
        
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                bluebaruPeripheral = peripheral

            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        centralMgr.stopScan()
        print(peripheral)

        bluebaruPeripheral = peripheral
        peripheral.delegate = self
        centralMgr.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("disconnected")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print(peripheral.services)
        if let svcs = peripheral.services {
            for service in svcs {
                if service.uuid == bluebaruDummySvcUUID {
                    peripheral.discoverCharacteristics([bluebaryDummyCharUUID], for: service)
                } else if service.uuid == bluebaruUARTSvcUUID {
                    peripheral.discoverCharacteristics([bluebaruUARTRxCharUUID], for: service)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let chars = service.characteristics {
            for character in chars {
                if character.uuid == bluebaruUARTTxCharUUID {
                    uartTXCharacteristic = character
                    
                    peripheral.setNotifyValue(true, for: character)
                } else if character.uuid == bluebaruUARTRxCharUUID {
                    uartRXCharacteristic = character
                    
                    sendAuth()
                } else if character.uuid == bluebaryDummyCharUUID {
                    peripheral.readValue(for: character)
                }
            }
        }
    }

    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        print("char value is \(String(describing: characteristic.value))")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        print("notified")
    }
}

private extension String {
    func split(by length: Int) -> [String] {
        var startIndex = self.startIndex
        var results = [Substring]()
        
        while startIndex < endIndex {
            let endIndex = index(startIndex, offsetBy: length, limitedBy: self.endIndex) ?? self.endIndex
            results.append(self[startIndex..<endIndex])
            startIndex = endIndex
        }
        
        return results.map { String($0) }
    }
}
