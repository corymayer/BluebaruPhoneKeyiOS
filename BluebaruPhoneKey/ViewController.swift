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
import zlib

class ViewController: UIViewController {
    let centralRestoreId = "bluebaru"
    let batSvcUUID = CBUUID(string: "180F")
    let bluebaruDummySvcUUID = CBUUID(string: "963E")
    let bluebaryDummyCharUUID = CBUUID(string: "963E")
    let bluebaruUARTSvcUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    let bluebaruUARTRxCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    let bluebaruUARTTxCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    let key = SymmetricKey(data: "w9z$C&E)H@McQfTjWnZr4u7x!A%D*G-J".data(using: .ascii)!) // CHANGE TO YOUR OWN KEY
    
    let cmdTypeAuthenticate = 7
    let authChallengeMsg = "authChallenge"
    let nonceLen = 12
    
    @IBOutlet weak var batLvlLabel: UILabel!
    @IBOutlet weak var connectedLabel: UILabel!
    
    var centralMgr: CBCentralManager!
    var bluebaruPeripheral: CBPeripheral?
    var uartRXCharacteristic: CBCharacteristic?
    var uartTXCharacteristic: CBCharacteristic?
    var batChar: CBCharacteristic?
    
    var nonce: UInt64 = 0
    
    struct UartPktHdrPlain {
        let crc: UInt32
        let pktLen: UInt32
        let nonce: UInt64
    }

    struct UartPktHdrEncrypted {
        let cmd: UInt32
        let dataLen: UInt32
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        // restore nonce
        nonce = UInt64(UserDefaults.standard.integer(forKey: "nonce"))
        if (nonce == 0) {
            nonce = 1
        }
        print("Restored nonce: \(nonce)")
        
        centralMgr = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey : centralRestoreId])
    }
    
    @IBAction func connectPress(_ sender: Any) {
        if let periph = bluebaruPeripheral, periph.state == .disconnected {
            centralMgr.connect(periph, options: nil)
        }
    }
    
    @IBAction func disconnectPress(_ sender: Any) {
        if let periph = bluebaruPeripheral, periph.state == .connected {
            centralMgr.cancelPeripheralConnection(periph)
        }
    }
    
    @IBAction func updateBatteryPress(_ sender: Any) {
        if let periph = bluebaruPeripheral, let character = batChar {
            periph.readValue(for: character)
        }
    }
    
    
    // TODO write out own UART send for data
    func uartSend(withData data: Data) {
        guard uartRXCharacteristic != nil else {
            print("UART RX Characteristic not found")
            return
        }
        guard let bluetoothPeripheral = bluebaruPeripheral else {
            print("No peripheral")
            return
        }
        
        let typeAsString = ".withResponse"
        
        print("Writing to characteristic: \(uartRXCharacteristic!.uuid.uuidString)")
        print("peripheral.writeValue(\(data.hexString)), for: \(uartRXCharacteristic!.uuid.uuidString), type: \(typeAsString))")
        bluetoothPeripheral.writeValue(data, for: uartRXCharacteristic!, type: .withResponse)
        print("\"\(data.hexString)\" sent")
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
        
        print("Writing to characteristic: \(uartRXCharacteristic!.uuid.uuidString)")
        print("peripheral.writeValue(\(aText)), for: \(uartRXCharacteristic!.uuid.uuidString), type: \(typeAsString))")
        bluetoothPeripheral.writeValue(data, for: uartRXCharacteristic!, type: aType)
        print("\"\(aText)\" sent")
    }
    
    /**
            Sends the authentication challenge response over BLE UART.
     */
    func sendAuth() {
        let tagSize = 16
        let bufSize = MemoryLayout<UartPktHdrPlain>.size + MemoryLayout<UartPktHdrEncrypted>.size + tagSize
        
        var byteArr = [UInt8](repeating: 0, count: bufSize)
        
        // determine nonce
        let curNonce = nonce
        let padding = Data(count: 4)
        let nonceData = padding + withUnsafeBytes(of: curNonce) { Data($0) }
        let nonceObj = try! ChaChaPoly.Nonce(data: nonceData)
        nonce += 1
        UserDefaults.standard.set(nonce, forKey: "nonce")
        
        // build headers
        var hdrPlain = UartPktHdrPlain(crc: 0, pktLen: UInt32(bufSize), nonce: curNonce)
        var hdrEncrypted = UartPktHdrEncrypted(cmd: UInt32(cmdTypeAuthenticate), dataLen: 0)
        
        byteArr.withContiguousMutableStorageIfAvailable { (bufPtr) in
            var rawPtr = UnsafeMutableRawPointer(bufPtr.baseAddress!)
            
            // write plaintext section header
            let hdrPlainLen = MemoryLayout.size(ofValue: hdrPlain)
            rawPtr.copyMemory(from: &hdrPlain, byteCount: hdrPlainLen)
            rawPtr += hdrPlainLen
            
            // write encrypted section header
            let hdrEncLen = MemoryLayout.size(ofValue: hdrEncrypted)
            rawPtr.copyMemory(from: &hdrEncrypted, byteCount: hdrEncLen)
            
            // encrypt cmd+data (only need the encrypted header since there is no encrypted data here)
            let dataToEncrypt = Data(bytes: UnsafeMutableRawPointer(bufPtr.baseAddress!) + hdrPlainLen, count: hdrEncLen)
            let encryptedBox = try! ChaChaPoly.seal(dataToEncrypt, using: key, nonce: nonceObj)
            print(encryptedBox.ciphertext)
            
            // write encrypted data
            encryptedBox.ciphertext.withUnsafeBytes { (cipertextBuf) in
                assert(encryptedBox.ciphertext.count == hdrEncLen)
                rawPtr.copyMemory(from: cipertextBuf.baseAddress!, byteCount: encryptedBox.ciphertext.count)
            }
            rawPtr += hdrEncLen
            
            // write tag
            encryptedBox.tag.withUnsafeBytes { (tagBuf) in
                assert(encryptedBox.tag.count == tagSize)
                rawPtr.copyMemory(from: tagBuf.baseAddress!, byteCount: encryptedBox.tag.count)
            }
        }
        
        // crc the whole packet
        var crc = CRC32.checksum(bytes: byteArr)
        print(NSString(format:"CRC: %2X", crc))
        
        // write CRC
        byteArr.withContiguousMutableStorageIfAvailable { (bufPtr) in
            let rawPtr = UnsafeMutableRawPointer(bufPtr.baseAddress!)
            
            rawPtr.copyMemory(from: &crc, byteCount: MemoryLayout.size(ofValue: crc))
            
            for byte in bufPtr {
                print(byte)
            }
            
            let crcCheck = rawPtr.load(as: UInt32.self)
            print(NSString(format:"CRC check: %2X", crcCheck))
            assert(crcCheck == crc)
        }
        
        let payloadData = Data(bytes: byteArr, count: byteArr.count)
        uartSend(withData: payloadData)
    }
}

// MARK: - CoreBluetooth
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
            
            if bluebaruPeripheral != nil && batChar == nil {
                bluebaruPeripheral?.discoverServices(nil)
            }
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
                bluebaruPeripheral?.delegate = self
                
                if peripheral.state == .connected {
                    connectedLabel.text = "yes"
                } else if peripheral.state == .disconnected {
                    connectedLabel.text = "no"
                    central.connect(peripheral, options: nil)
                }
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
        print("connected")
        connectedLabel.text = "yes"
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedLabel.text = "no"
        if (peripheral == bluebaruPeripheral) {
            print("Reconnecting")
            centralMgr.connect(peripheral, options: nil)
        } else {
            print("unknown peripheral")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let svcs = peripheral.services {
            for service in svcs {
                if service.uuid == bluebaruDummySvcUUID {
                    peripheral.discoverCharacteristics([bluebaryDummyCharUUID], for: service)
                } else if service.uuid == bluebaruUARTSvcUUID {
                    peripheral.discoverCharacteristics([bluebaruUARTRxCharUUID, bluebaruUARTTxCharUUID], for: service)
                } else if service.uuid == batSvcUUID {
                    peripheral.discoverCharacteristics(nil, for: service)
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
                    
//                    sendAuth()
                } else if character.uuid == bluebaryDummyCharUUID {
//                    peripheral.readValue(for: character)
                } else if service.uuid == batSvcUUID {
                    batChar = character
                    
                    peripheral.readValue(for: character)
                }
            }
        }
    }

    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            print("Updating value has failed")
            return
        }
        
        if (characteristic.uuid == bluebaruUARTTxCharUUID) {
            // try to print a friendly string of received bytes if they can be parsed as UTF8
            guard let bytesReceived = characteristic.value else {
                print("Notification received from: \(characteristic.uuid.uuidString), with empty value")
                print("Empty packet received")
                return
            }
            
            print("Notification received from: \(characteristic.uuid.uuidString), with value: 0x\(bytesReceived.hexString)")
            if let validUTF8String = String(data: bytesReceived, encoding: .utf8) {
                print("\"\(validUTF8String)\" received")
                
                if validUTF8String == authChallengeMsg {
                    sendAuth()
                }
            } else {
                print("\"0x\(bytesReceived.hexString)\" received")
            }
        } else if (characteristic.uuid == bluebaryDummyCharUUID) {
            print("dummy char read")
        } else if (characteristic == batChar) {
            if let data = characteristic.value {
                let lvl = data.withUnsafeBytes { (ptr) -> UInt8 in
                    return ptr.load(as: UInt8.self)
                }
                batLvlLabel.text = String(lvl)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            print("Enabling notifications failed")
            return
        }
        
        if characteristic.isNotifying {
            print("Notifications enabled for characteristic: \(characteristic.uuid.uuidString)")
        } else {
            print("Notifications disabled for characteristic: \(characteristic.uuid.uuidString)")
        }
    }
}

// MARK: - Extensions
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

extension Data {
    internal var hexString: String {
        return map { String(format: "%02X", $0) }.joined()
    }
    
}
