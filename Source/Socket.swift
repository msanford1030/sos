//
//  Socket.swift
//
//  Created by Michael Sanford on 9/27/16.
//  Copyright © 2016 flipside5. All rights reserved.
//

import Foundation
import Darwin

enum SocketError: Error {
    case socketClosed
    case operationFailure(SocketErrorCode)
    case internalError
    case receivedDataFromUnexpectedSender
    case attemptNonBlockingOperationOnBlockingSocket
    
    fileprivate static var currentFailure: SocketError {
        return .operationFailure(SocketErrorCode.current)
    }
}

enum SocketOption {
    case SendBufferSize(Int)
    case ReceiveBufferSize(Int)
    case ReuseAddress(Bool)
    case KeepAlive(Bool)
    case ReceiveTimeout(Int)
    case SignalPipe(Bool)
    
    fileprivate var constant: Int32 {
        switch self {
        case .SendBufferSize: return SO_SNDBUF
        case .ReceiveBufferSize: return SO_RCVBUF
        case .ReuseAddress: return SO_REUSEADDR
        case .KeepAlive: return SO_KEEPALIVE
        case .ReceiveTimeout: return SO_RCVTIMEO
        case .SignalPipe: return SO_NOSIGPIPE
        }
    }
    
    fileprivate var value: UInt32 {
        switch self {
        case .SendBufferSize(let value): return UInt32(value)
        case .ReceiveBufferSize(let value): return UInt32(value)
        case .ReuseAddress(let flag): return flag ? 1 : 0
        case .KeepAlive(let flag): return flag ? 1 : 0
        case .ReceiveTimeout(let time): return UInt32(time)
        case .SignalPipe(let flag): return flag ? 1 : 0
        }
    }
    
    fileprivate static func create(_ option: SocketOption, value: UInt32) -> SocketOption {
        switch option {
        case .SendBufferSize: return .SendBufferSize(Int(value))
        case .ReceiveBufferSize: return .ReceiveBufferSize(Int(value))
        case .ReuseAddress: return .ReuseAddress(value != 0)
        case .KeepAlive: return .KeepAlive(value != 0)
        case .ReceiveTimeout: return .ReceiveTimeout(Int(value))
        case .SignalPipe: return .SignalPipe(value != 0)
        }
    }
}

/*---------------------------------------------------------------*/

typealias SocketRawHandle = Int32

fileprivate struct NativeSocket {
    let handle: SocketRawHandle
    let connectionType: ConnectionType
    let addressType: IPAddressType
    
    init?(addressType: IPAddressType = .version6, connectionType: ConnectionType) {
        let handle = Darwin.socket(Int32(addressType.family), connectionType.socketType, 0)
        guard handle >= 0 else { return nil }
        self.init(handle: handle, addressType: addressType, connectionType: connectionType)
    }
    
    init(handle: SocketRawHandle, addressType: IPAddressType, connectionType: ConnectionType) {
        self.handle = handle
        self.connectionType = connectionType
        self.addressType = addressType
    }
}

/*---------------------------------------------------------------*/

enum SelectOperationType {
    case read
    case close
    case error(SocketErrorCode)
}

class Socket {
    fileprivate var socket: NativeSocket?
    
    var handle: SocketRawHandle? {
        return socket?.handle
    }
    
    fileprivate init?(addressType: IPAddressType, connectionType: ConnectionType) {
        guard let socket = NativeSocket(addressType: addressType, connectionType: connectionType) else { return nil }
        self.socket = socket
    }
    
    fileprivate init(handle: SocketRawHandle, addressType: IPAddressType, connectionType: ConnectionType) {
        self.socket = NativeSocket(handle: handle, addressType: addressType, connectionType: connectionType)
    }
    
    var isNonBlockingEnabled: Bool {
        get {
            guard let socket = socket else { return true }
            let flags = fcntl(socket.handle, F_GETFL, 0)
            return (flags & O_NONBLOCK) != 0
        }
        set {
            guard let socket = socket else { return }
            
            if newValue {
                let flags = fcntl(socket.handle, F_GETFL, 0)
                let _ = Darwin.fcntl(socket.handle, F_SETFL, flags | O_NONBLOCK);
            } else {
                var flags = fcntl(socket.handle, F_GETFL, 0)
                flags = flags & (~O_NONBLOCK)
                let _ = Darwin.fcntl(socket.handle, F_SETFL, flags);
            }
        }
    }
    
    func addressType() throws -> IPAddressType {
        guard let socket = socket else { throw SocketError.socketClosed }
        return socket.addressType
    }
    
    func connectionType() throws -> ConnectionType {
        guard let socket = socket else { throw SocketError.socketClosed }
        return socket.connectionType
    }
    
    func getOption(_ option: SocketOption) throws -> SocketOption {
        guard let socket = socket else { throw SocketError.socketClosed }

        var value: UInt32 = 0
        var length: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        guard Darwin.getsockopt(socket.handle, SOL_SOCKET, option.constant, &value, &length) >= 0 else { throw SocketError.currentFailure }
        return SocketOption.create(option, value: value)
    }
    
    func setOption(_ option: SocketOption) throws {
        guard let socket = socket else { throw SocketError.socketClosed }

        var value: UInt32 = option.value
        guard Darwin.setsockopt(socket.handle, SOL_SOCKET, option.constant, &value, UInt32(MemoryLayout<UInt32>.size)) >= 0 else { throw SocketError.currentFailure }
    }
    
    func close() throws {
        guard let socket = socket else { throw SocketError.socketClosed }

        let result = Darwin.close(socket.handle)
        guard result >= 0 else { throw SocketError.currentFailure }
        self.socket = nil
    }
}

/*---------------------------------------------------------------*/

class UDPServerSocket: Socket {
    let port: Port
    
    required init?(port: Port, addressType: IPAddressType = .version4) {
        self.port = port
        super.init(addressType: addressType, connectionType: .udp)
        do {
            try setOption(.SendBufferSize(900))
            try setOption(.ReuseAddress(true))
        } catch {
            return nil
        }
    }

    func bind() throws {
        guard let socket = socket else { throw SocketError.socketClosed }
        
        let localAddress = IPAddress.localhost(withPort: port, type: socket.addressType)
        let result = localAddress.performOnPointer { Darwin.bind(socket.handle, $0, localAddress.type.size) }
        guard result >= 0 else { throw SocketError.currentFailure }
    }
    
    func receive(numberOfBytes: Int) throws -> (Data, IPAddress) {
        guard let socket = socket else { throw SocketError.socketClosed }
        return try socket.receive(numberOfBytes: numberOfBytes)
    }
    
    func send(_ data: Data, to clientAddress: IPAddress) throws {
        guard let socket = socket else { throw SocketError.socketClosed }
        try socket.send(data, to: clientAddress)
    }
}

class UDPClientSocket: Socket {
    let serverAddress: IPAddress
    
    required init?(serverAddress: IPAddress) {
        self.serverAddress = serverAddress
        super.init(addressType: serverAddress.type, connectionType: .udp)
    }
    
    func connect() throws {
        guard let socket = socket else { throw SocketError.socketClosed }

        let result = serverAddress.performOnPointer { Darwin.connect(socket.handle, $0, serverAddress.type.size) }
        guard result >= 0 else { throw SocketError.currentFailure }
    }
    
    func receive(numberOfBytes: Int) throws -> Data {
        guard let socket = socket else { throw SocketError.socketClosed }
        let (data, from) = try socket.receive(numberOfBytes: numberOfBytes)
        guard from == serverAddress else { throw SocketError.receivedDataFromUnexpectedSender }
        return data
    }
    
    func send(_ data: Data) throws {
        guard let socket = socket else { throw SocketError.socketClosed }
        try socket.send(data, to: serverAddress)
    }
}

// UDP extension
fileprivate extension NativeSocket {
    
    func receive(numberOfBytes: Int) throws -> (Data, IPAddress) {
        var rawClientAddress: sockaddr_in6 = sockaddr_in6()
        return try withUnsafePointer(to: &rawClientAddress) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                var addressLength: socklen_t = IPAddressType.version6.size
                var buffer = Array<UInt8>(repeating: 0, count: numberOfBytes)
                let pointer = UnsafeMutablePointer<sockaddr>(mutating: $0)
                let bytesReadCount = Darwin.recvfrom(handle, &buffer, numberOfBytes, 0, pointer, &addressLength)
                guard bytesReadCount > 0 else {
                    throw SocketError.currentFailure
                }
                guard let clientAddress = IPAddress(addressPtr: $0, size: addressLength) else { throw SocketError.internalError }
                let data = Data(bytes: &buffer, count: bytesReadCount)
                return (data, clientAddress)
            }
        }
    }
    
    func send(_ data: Data, to remoteAddress: IPAddress) throws {
        let byteSendCount: Int = data.withUnsafeBytes { (dataPtr: UnsafePointer<UInt8>) -> Int in
            return remoteAddress.performOnPointer { (addressPtr: UnsafePointer<sockaddr>) -> Int in
                let result: Int = Darwin.sendto(handle, dataPtr, data.count, 0, addressPtr, remoteAddress.type.size)
                return result
            }
        }
        guard byteSendCount == data.count else { throw SocketError.currentFailure }
    }
    
}

/*---------------------------------------------------------------*/

class TCPClientSocket: Socket {
    let remoteAddress: IPAddress
    
    init?(remoteAddress: IPAddress) {
        self.remoteAddress = remoteAddress
        super.init(addressType: remoteAddress.type, connectionType: .tcp)
    }
    
    fileprivate init(remoteAddress: IPAddress, handle: SocketRawHandle) {
        self.remoteAddress = remoteAddress
        super.init(handle: handle, addressType: remoteAddress.type, connectionType: .tcp)
    }
    
    func connect() throws {
        guard let socket = socket else { throw SocketError.socketClosed }
        
        let result = remoteAddress.performOnPointer { Darwin.connect(socket.handle, $0, remoteAddress.type.size) }
        guard result >= 0 else { throw SocketError.currentFailure }
    }
    
    func read(numberOfBytes: Int) throws -> Data? {
        guard let socket = socket else { throw SocketError.socketClosed }
        var buffer = Array<UInt8>(repeating: 0, count: numberOfBytes)
        let result = Darwin.read(socket.handle, &buffer, numberOfBytes)
        guard result != 0 else { return nil }
        guard result > 0 else { throw SocketError.currentFailure }
        return Data(bytes: &buffer, count: numberOfBytes)
    }
    
    func write(_ data: Data) throws {
        guard let socket = socket else { throw SocketError.socketClosed }
        
        let result = data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> Int in
            return Darwin.write(socket.handle, ptr, data.count)
        }
        guard result == data.count else { throw SocketError.currentFailure }
    }
}

class TCPServerSocket: Socket {
    private enum StreamMode {
        case unbound(Port)
        case acceptingConnections(Port)
        case closed
    }
    
    private var mode: StreamMode = .unbound(0)
    
    init?(port: Port, type: IPAddressType = IPAddress.localhost().type) {
        self.mode = .unbound(port)
        super.init(addressType: type, connectionType: .tcp)
        
        do {
            try setOption(.ReuseAddress(true))
        } catch {
            return nil
        }
    }
    
    func listen(withBacklog backlog: Int = 128) throws {
        guard let socket = socket else { throw SocketError.socketClosed }

        let result = Darwin.listen(socket.handle, Int32(backlog))
        guard result >= 0 else { throw SocketError.currentFailure }
    }
    
    func bind() throws {
        guard let socket = socket else { throw SocketError.socketClosed }
        guard case .unbound(let localPort) = mode else { throw SocketError.internalError }

        let localAddress = IPAddress.localhost(withPort: localPort)
        let result = localAddress.performOnPointer { Darwin.bind(socket.handle, $0, localAddress.type.size) }
        guard result >= 0 else { throw SocketError.currentFailure }
        mode = .acceptingConnections(localPort)
    }
    
    func accept() throws -> TCPClientSocket? {
        guard let socket = socket else { throw SocketError.socketClosed }
        guard case .acceptingConnections = mode else { throw SocketError.internalError }

        var rawClientAddress: sockaddr_in6 = sockaddr_in6()
        return try withUnsafePointer(to: &rawClientAddress) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                var addressLength: socklen_t = IPAddressType.version6.size
                let pointer = UnsafeMutablePointer<sockaddr>(mutating: $0)
                let handle = Darwin.accept(socket.handle, pointer , &addressLength)
                guard handle >= 0 else { return nil }
                guard let clientAddress = IPAddress(addressPtr: $0, size: addressLength) else { throw SocketError.internalError }
                return TCPClientSocket(remoteAddress: clientAddress, handle: handle)
            }
        }
    }
    
    override func close() throws {
        self.mode = .closed
        try super.close()
    }
}

/*---------------------------------------------------------------*/

fileprivate extension ConnectionType {
    var socketType: Int32 {
        switch self {
        case .tcp: return SOCK_STREAM
        case .udp: return SOCK_DGRAM
        }
    }
}

fileprivate extension IPAddressType {
    var family: sa_family_t {
        switch self {
        case .version6: return sa_family_t(PF_INET6)
        case .version4: return sa_family_t(PF_INET)
        }
    }
}
