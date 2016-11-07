//
//  IPAddress.swift
//
//  Created by Michael Sanford on 9/25/16.
//  Copyright © 2016 flipside5. All rights reserved.
//

import Foundation
import Darwin

fileprivate struct ifaddrs {
    var ifa_next: UnsafePointer<ifaddrs>
    var ifa_name: UnsafePointer<UInt8>
    var ifa_flags: UInt32
    var ifa_addr: UnsafePointer<sockaddr>
    var ifa_netmask: UnsafePointer<sockaddr>
    var ifa_dstaddr: UnsafePointer<sockaddr>
    var fa_data: UnsafePointer<UInt8>
}

@_silgen_name("getifaddrs") fileprivate func sys_getifaddrs(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>>) -> Int32
@_silgen_name("freeifaddrs") fileprivate func sys_freeifaddrs(_ ptr: UnsafeMutablePointer<ifaddrs>) -> Int32

typealias Port = UInt16
private let DefaultIPAddressType: IPAddressType = .version4

enum IPAddressType {
    case version6
    case version4
    
    var size: UInt32 {
        switch self {
        case .version6: return UInt32(MemoryLayout<sockaddr_in6>.size)
        case .version4: return UInt32(MemoryLayout<sockaddr_in>.size)
        }
    }
    
    static func forSize(size: UInt32) -> IPAddressType? {
        switch size {
        case IPAddressType.version6.size: return .version6
        case IPAddressType.version4.size: return .version4
        default: return nil
        }
    }
}

fileprivate enum RawIPAddress: Hashable {
    case version6(sockaddr_in6)
    case version4(sockaddr_in)
    
    fileprivate static func rawIPAddress(withAddressPtr addressPtr: UnsafePointer<sockaddr>, type: IPAddressType) -> RawIPAddress? {
        switch type {
        case .version6:
            var v6Address = addressPtr.pointee
            return withUnsafePointer(to: &v6Address) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { RawIPAddress.version6($0.pointee) } }
        case .version4:
            let address = unsafeBitCast(addressPtr.pointee, to: sockaddr_in.self)
            return RawIPAddress.version4(address)
        }
    }
    
    var hashValue: Int {
        switch self {
        case .version6(let address):
            return Int(UInt32(address.sin6_addr.__u6_addr.__u6_addr32.2) + (UInt32(UInt32.max) / 2) + UInt32(address.sin6_port))
        case .version4(let address):
            return Int(UInt32(address.sin_addr.s_addr) + (UInt32(UInt32.max) / 2) + UInt32(address.sin_port))
        }
    }
    
    var rawValue: sockaddr {
        switch self {
        case .version6(let address):
            var localAddress = address
            return withUnsafePointer(to: &localAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee } }
        case .version4(let address):
            return unsafeBitCast(address, to: sockaddr.self)
        }
    }
    
    var size: UInt32 {
        switch self {
        case .version6: return IPAddressType.version6.size
        case .version4: return IPAddressType.version4.size
        }
    }
    
    fileprivate static func components(fromSocketPointer socketPtr: UnsafePointer<sockaddr>) -> (String, String)? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var portBuffer = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        
        guard getnameinfo(socketPtr, socklen_t(socketPtr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), &portBuffer, socklen_t(portBuffer.count), NI_NUMERICHOST | NI_NUMERICSERV) == 0
            else { return nil }
        
        let hostString = String(cString: hostBuffer)
        let portString = String(cString: portBuffer)
        return (hostString, portString)
    }
    
    fileprivate var components: (String, String)? {
        return performOnPointer { RawIPAddress.components(fromSocketPointer: $0) }
    }
    
    fileprivate static func formattedString(withIPAddress ipAddress: String, port: String) -> String {
        return "\(ipAddress):\(port)"
    }
    
    fileprivate func performOnPointer<Result>(body: (UnsafePointer<sockaddr>) -> Result) -> Result {
        switch self {
        case .version6(let address):
            var localAddress = address
            return withUnsafePointer(to: &localAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) } }
        case .version4(let address):
            var localAddress = address
            return withUnsafePointer(to: &localAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) } }
        }
    }
}

fileprivate func ==(lhs: RawIPAddress, rhs: RawIPAddress) -> Bool {
    switch (lhs, rhs) {
    case (.version6(let l6), .version6(let r6)):
        return l6.sin6_len == r6.sin6_len &&
            l6.sin6_family == r6.sin6_family &&
            l6.sin6_port == r6.sin6_port &&
            l6.sin6_flowinfo == r6.sin6_flowinfo &&
            l6.sin6_addr.__u6_addr.__u6_addr32 == r6.sin6_addr.__u6_addr.__u6_addr32 &&
            l6.sin6_scope_id == r6.sin6_scope_id
    case (.version4(let l4), .version4(let r4)):
        return l4.sin_len == r4.sin_len &&
            l4.sin_family == r4.sin_family &&
            l4.sin_port == r4.sin_port &&
            l4.sin_addr.s_addr == r4.sin_addr.s_addr
    default: return false
    }
}

/*--------------------------------------------------*/

struct IPAddress: Hashable {
    let ipAddress: String
    let port: Port
    private let _hashValue: Int
    fileprivate let rawAddress: RawIPAddress
    fileprivate let formatted: String
    
    static func localhost(withPort port: Port? = nil, type: IPAddressType = DefaultIPAddressType) -> IPAddress {
        switch type {
        case .version6:
            return IPAddress(ipAddress: "::1", port: port)!
        case .version4:
            return IPAddress(ipAddress: "127.0.0.1", port: port)!
        }
    }
    
    var hashValue: Int {
        return _hashValue
    }
    
    var type: IPAddressType {
        switch rawAddress {
        case .version6: return IPAddressType.version6
        case .version4: return IPAddressType.version4
        }
    }
    
    init?(ipAddress: String, port: Port? = nil) {
        if let address = socketAddress6(fromIP: ipAddress, port: port) {
            self.init(.version6(address))
        } else if let address = socketAddress4(fromIP: ipAddress, port: port) {
            self.init(.version4(address))
        } else {
            return nil
        }
    }
    
    fileprivate init?(_ rawAddress: RawIPAddress) {
        self.rawAddress = rawAddress
        self._hashValue = rawAddress.hashValue
        
        guard let (ipString, portString) = rawAddress.components else { return nil }
        guard let port = Port(portString) else { return nil }
        self.ipAddress = ipString
        self.port = port
        self.formatted = RawIPAddress.formattedString(withIPAddress: ipString, port: portString)
    }
    
    init?(addressPtr: UnsafePointer<sockaddr>, size: UInt32) {
        guard let type = IPAddressType.forSize(size: size),
            let rawAddress = RawIPAddress.rawIPAddress(withAddressPtr: addressPtr, type: type) else { return nil }
        self.init(rawAddress)
    }
    
    func performOnPointer<Result>(body: (UnsafePointer<sockaddr>) -> Result) -> Result {
        return rawAddress.performOnPointer(body: body)
    }
}

func ==(lhs: IPAddress, rhs: IPAddress) -> Bool {
    return lhs.rawAddress == rhs.rawAddress
}

extension String {
    fileprivate init?(describing socketPtr: UnsafePointer<sockaddr>) {
        guard let (ipString, portString) = RawIPAddress.components(fromSocketPointer: socketPtr) else { return nil }
        self.init(RawIPAddress.formattedString(withIPAddress: ipString, port: portString))
    }
    
    fileprivate init?(reflecting socketPtr: UnsafePointer<sockaddr>) {
        self.init(describing: socketPtr)
    }
    
    fileprivate init?(describing rawIPAddress: RawIPAddress) {
        guard let (ipString, portString) = rawIPAddress.components else { return nil }
        self.init(RawIPAddress.formattedString(withIPAddress: ipString, port: portString))
    }
    
    fileprivate init?(reflecting rawIPAddress: RawIPAddress) {
        self.init(describing: rawIPAddress)
    }
    
    init?(describing ipAddress: IPAddress) {
        self.init(ipAddress.formatted)
    }
    
    init?(reflecting ipAddress: IPAddress) {
        self.init(ipAddress.formatted)
    }
}

/*--------------------------------------------------*/

fileprivate func socketAddress6(fromIP ipv6: String, port: Port?) -> sockaddr_in6? {
    let AddressPartCount = 8
    let parts = ipv6.components(separatedBy: ":")
    guard parts.count <= AddressPartCount else { return nil }
    var addressString = ipv6
    if parts.count < AddressPartCount {
        let prefix = String(repeating: ":", count: AddressPartCount - parts.count)
        addressString = "\(prefix)\(ipv6)"
    }

    let fullIPv6 = addressString.components(separatedBy: ":")
        .map { $0.characters.count == 0 ? "0\($0)" : $0 }
        .reduce("") { (result, part) in result.characters.count == 0 ? part : "\(result):\(part)" }
    
    var sin6 = sockaddr_in6()
    sin6.sin6_len = __uint8_t(IPAddressType.version6.size)
    sin6.sin6_family = sa_family_t(AF_INET6)
    sin6.sin6_port = in_port_t(0)
    sin6.sin6_addr = in6addr_any
    sin6.sin6_scope_id = __uint32_t(0)
    sin6.sin6_flowinfo = __uint32_t(0)
    
    guard fullIPv6.withCString({ cs in inet_pton(AF_INET6, cs, &sin6.sin6_addr) }) == 1 else { return nil }
    if let port = port {
        sin6.sin6_port = in_port_t(port.bigEndian)
    }
    return sin6
}

fileprivate func socketAddress4(fromIP ipv4: String, port: Port?) -> sockaddr_in? {
    var sin4 = sockaddr_in(sin_len:__uint8_t(IPAddressType.version4.size),
                           sin_family:sa_family_t(AF_INET),
                           sin_port:in_port_t(0),
                           sin_addr:in_addr(s_addr: 0), sin_zero:(Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
    )
    
    guard ipv4.withCString({ cs in inet_pton(AF_INET, cs, &sin4.sin_addr) }) == 1 else { return nil }
    if let port = port {
        sin4.sin_port = in_port_t(port.bigEndian)
    }
    return sin4
}
