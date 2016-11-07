//
//  SocketRunLoop.swift
//
//  Created by Michael Sanford on 11/6/16.
//  Copyright © 2016 flipside5. All rights reserved.
//

import Foundation

protocol TCPRunLoopDelegate {
    func runLoop(_ runLoop: TCPRunLoop, serverSocket: TCPServerSocket, didReceiveConnectionRequestFrom clientSocket: TCPClientSocket)
    func runLoop(_ runLoop: TCPRunLoop, serverSocket: TCPServerSocket, didCloseWithError: SocketErrorCode?)
    
    func runLoop(_ runLoop: TCPRunLoop, clientSocket: TCPClientSocket, didReceiveDataWithContext context: Any?)
    func runLoop(_ runLoop: TCPRunLoop, clientSocket: TCPClientSocket, didCloseWithError: SocketErrorCode?, context: Any?)
}

fileprivate enum TCPCallbackInfo {
    case client(socket: TCPClientSocket, context: Any?)
    case server(socket: TCPServerSocket)
    
    func close() throws {
        switch self {
        case .client(let socket, _):
            try socket.close()
        case .server(let socket):
            try socket.close()
        }
    }
}

fileprivate enum TCPRunLoopState {
    case running
    case stopping
    case stopped
}

class TCPRunLoop {
    
    private var emptyByte = UInt8(0)
    private let delegate: TCPRunLoopDelegate
    private var kqueueId: Int32
    private var socketList: Set<kevent>
    private let queue: DispatchQueue
    private var isDirty: Bool = false
    private var state: TCPRunLoopState
    private var callbackInfos: [SocketRawHandle: TCPCallbackInfo]
    private var eventHandle: SocketRawHandle
    private var triggerHandle: SocketRawHandle
    
    init?(delegate: TCPRunLoopDelegate) {
        let kqueueId = kqueue()
        guard kqueueId != -1 else { return nil }
        self.kqueueId = kqueueId
        state = .stopped
        queue = DispatchQueue.init(label: "SocketRunLoop")
        callbackInfos = [:]
        self.delegate = delegate
        
        var socketPair: [SocketRawHandle]
        socketPair = Array(repeating: SocketRawHandle(0), count: 2)
        socketpair(PF_LOCAL, SOCK_STREAM, 0, &socketPair)
        eventHandle = socketPair[0]
        triggerHandle = socketPair[1]
        
        socketList = Set<kevent>()
        var ev = kevent()
        ev.set(ident: UInt(eventHandle), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0)
        socketList.insert(ev)
    }
    
    func add(socket: TCPServerSocket) throws {
        guard let handle = socket.handle else { throw SocketError.socketClosed }
        
        var ev = kevent()
        let callbackInfo = TCPCallbackInfo.server(socket: socket)
        let ptr = UnsafeMutablePointer<TCPCallbackInfo>.allocate(capacity: 1)
        ptr.initialize(to: callbackInfo)
        
        ev.set(ident: UInt(handle), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: UnsafeMutableRawPointer(ptr))
        queue.sync {
            callbackInfos[handle] = callbackInfo
            socketList.insert(ev)
            isDirty = true
        }
        
        // trigger event in run loop
        if case .running = state {
            _ = Darwin.write(triggerHandle, &emptyByte, 1)
        }
    }
    
    func add(socket: TCPClientSocket, context: Any?) throws {
        guard let handle = socket.handle else { throw SocketError.socketClosed }
        if case .stopping = state { return }
        
        var ev = kevent()
        let callbackInfo = TCPCallbackInfo.client(socket: socket, context: context)
        let ptr = UnsafeMutablePointer<TCPCallbackInfo>.allocate(capacity: 1)
        ptr.initialize(to: callbackInfo)
        
        ev.set(ident: UInt(handle), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: UnsafeMutableRawPointer(ptr))
        queue.sync {
            callbackInfos[handle] = callbackInfo
            socketList.insert(ev)
            isDirty = true
        }
        
        // trigger event in run loop
        if case .running = state {
            _ = Darwin.write(triggerHandle, &emptyByte, 1)
        }
    }
    
    func remove(socket: TCPClientSocket) throws {
        guard let handle = socket.handle else { throw SocketError.socketClosed }
        if case .stopping = state { return }
        queue.sync {
            callbackInfos[handle] = nil
            var ev = kevent()
            ev.set(ident: UInt(handle), filter: 0, flags: 0, fflags: 0, data: 0)
            socketList.remove(ev)
            isDirty = true
        }
        
        // trigger event in run loop
        if case .running = state {
            _ = Darwin.write(triggerHandle, &emptyByte, 1)
        }
    }
    
    func run() {
        queue.sync {
            state = .running
        }
        
        var socketListCopy: [kevent] = []
        var socketCount: Int32 = 0
        var isRunning = true
        while isRunning {
            queue.sync {
                guard case .running = state else {
                    isRunning = false
                    return
                }
                guard isDirty else { return }
                
                socketCount = Int32(socketList.count)
                socketListCopy = Array<kevent>(socketList)
                isDirty = false
            }
            guard isRunning else { continue }
            
            var eventList: [kevent] = Array(repeating: kevent(), count: Int(socketCount))
            let result = kevent(kqueueId, &socketListCopy, socketCount, &eventList, socketCount, nil)
            
            guard result != -1 else {
                return
            }
            
            guard result != 0 else { continue }
            
            let subEventList = eventList[0..<Int(result)]
            subEventList.forEach { event in
                guard event.ident != 0 else { return }
                guard event.ident != UInt(eventHandle) else {
                    var buffer: UInt8 = 0
                    _ = Darwin.read(eventHandle, &buffer, 1)
                    return
                }
                
                let eventFlags = Int32(event.flags)
                let socketHandle = SocketRawHandle(event.ident)
                let callbackInfo = event.udata.bindMemory(to: TCPCallbackInfo.self, capacity: 1).pointee
                print("result=\(result), eventFlags=\(eventFlags)")
                if (eventFlags & EV_EOF) != 0 {
                    // close socket do to disconnect
                    queue.sync {
                        callbackInfos[socketHandle] = nil
                        socketList.remove(event)
                    }
                    switch callbackInfo {
                    case .client(let socket, let context):
                        self.delegate.runLoop(self, clientSocket: socket, didCloseWithError: nil, context: context)
                    case .server(let socket):
                        self.delegate.runLoop(self, serverSocket: socket, didCloseWithError: nil)
                    }
                } else if (eventFlags & EVFILT_READ) != 0 {
                    // read
                    switch callbackInfo {
                    case .client(let socket, let context):
                        self.delegate.runLoop(self, clientSocket: socket, didReceiveDataWithContext: context)
                    case .server(let socket):
                        do {
                            guard let clientSocket = try socket.accept() else {
                                self.delegate.runLoop(self, serverSocket: socket, didCloseWithError: SocketErrorCode.current)
                                isRunning = false
                                return
                            }
                            
                            self.delegate.runLoop(self, serverSocket: socket, didReceiveConnectionRequestFrom: clientSocket)
                            
                        } catch {
                            self.delegate.runLoop(self, serverSocket: socket, didCloseWithError: SocketErrorCode.current)
                            isRunning = false
                        }
                    }
                }
            }
            
        }
        
        queue.sync {
            state = .stopped
        }
        
    }

    func stop(withCloseAllEnabled closeAllEnabled: Bool = true) {
        queue.sync {
            state = .stopping
            if closeAllEnabled {
                do {
                    try callbackInfos.values.forEach { try $0.close() }
                } catch {
                }
            }
        }
        
        let waitOp = BlockOperation() { [weak self] in
            var isStopped = false
            while !isStopped {
                Thread.sleep(forTimeInterval: 0.005)
                guard let strongSelf = self else { return }
                strongSelf.queue.sync {
                    if case .stopped = strongSelf.state {
                        isStopped = true
                    }
                }
            }
        }
        
        let waitQueue = OperationQueue()
        waitQueue.addOperation(waitOp)
        waitOp.waitUntilFinished()
    }
}

/*---------------------------------------------------------------*/

extension kevent: Hashable {
    mutating func set(ident: UInt, filter: Int16, flags: UInt16, fflags: UInt32, data: Int, udata: UnsafeMutableRawPointer? = nil) {
        self.ident = ident
        self.filter = filter
        self.flags = flags
        self.fflags = fflags
        self.data = data
        self.udata = udata
    }
    
    public var hashValue: Int {
        return Int(ident)
    }
}

public func ==(lhs: kevent, rhs: kevent) -> Bool {
    return lhs.ident == rhs.ident
}
