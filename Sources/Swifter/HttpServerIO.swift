//
//  HttpServer.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation

public class HttpServerIO {
    
    private var listenSocket: Socket = Socket(socketFileDescriptor: -1)
    private var clientSockets: Set<Socket> = []
    private let clientSocketsLock = NSLock()
    
    public typealias MiddlewareCallback = HttpRequest -> HttpResponse?
    
    public var middleware = [MiddlewareCallback]()
    
    public func start(_ listenPort: in_port_t = 8080) throws {
        stop()
        listenSocket = try Socket.tcpSocketForListen(listenPort)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) {
            while let socket = try? self.listenSocket.acceptClientSocket() {
                self.lock(self.clientSocketsLock) {
                    self.clientSockets.insert(socket)
                }
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), {
                    self.handleConnection(socket)
                    self.lock(self.clientSocketsLock) {
                        self.clientSockets.remove(socket)
                    }
                })
            }
            self.stop()
        }
        
    }
    
    public func stop() {
        listenSocket.release()
        lock(self.clientSocketsLock) {
            for socket in self.clientSockets {
                socket.shutdwn()
            }
            self.clientSockets.removeAll(keepingCapacity: true)
        }
    }
    
    public func dispatch(_ method: String, path: String) -> ([String: String], HttpRequest -> HttpResponse) {
        return ([:], { _ in HttpResponse.NotFound })
    }
    
    private func handleConnection(_ socket: Socket) {
        let address = try? socket.peername()
        let parser = HttpParser()
        while let request = try? parser.readHttpRequest(socket) {
            request.address = address
            var response = askMiddlewareForResponse(request)
            if response == nil {
                let (params, handler) = self.dispatch(request.method, path: request.path)
                request.params = params
                response = handler(request)
            }
            var keepConnection = parser.supportsKeepAlive(request.headers)
            do {
                keepConnection = try self.respond(socket, response: response!, keepAlive: keepConnection)
            } catch {
                print("Failed to send response: \(error)")
                break
            }
            if let session = response!.socketSession() {
                session(socket)
                break
            }
            if !keepConnection { break }
        }
        socket.release()
    }

    private func askMiddlewareForResponse(_ request: HttpRequest) -> HttpResponse? {
        for layer in middleware {
            if let response = layer(request) {
                return response
            }
        }
        return nil
    }
    
    private func lock(_ handle: NSLock, closure: () -> ()) {
        handle.lock()
        closure()
        handle.unlock();
    }
    
    private struct InnerWriteContext: HttpResponseBodyWriter {
        let socket: Socket
        func write(_ data: [UInt8]) {
            write(ArraySlice(data))
        }
        func write(_ data: ArraySlice<UInt8>) {
            do {
                try socket.writeUInt8(data)
            } catch {
                print("\(error)")
            }
        }
    }
    
    private func respond(_ socket: Socket, response: HttpResponse, keepAlive: Bool) throws -> Bool {
        try socket.writeUTF8("HTTP/1.1 \(response.statusCode()) \(response.reasonPhrase())\r\n")
        
        let content = response.content()
        
        if content.length >= 0 {
            try socket.writeUTF8("Content-Length: \(content.length)\r\n")
        }
        
        if keepAlive && content.length != -1 {
            try socket.writeUTF8("Connection: keep-alive\r\n")
        }
        
        for (name, value) in response.headers() {
            try socket.writeUTF8("\(name): \(value)\r\n")
        }
        
        try socket.writeUTF8("\r\n")
    
        if let writeClosure = content.write {
            let context = InnerWriteContext(socket: socket)
            try writeClosure(context)
        }
        
        return keepAlive && content.length != -1;
    }
}

#if os(Linux)
    
    import Glibc
    
    let DISPATCH_QUEUE_PRIORITY_BACKGROUND = 0
    
    private class dispatch_context {
        let block: (Void -> Void)
        init(_ block: (Void -> Void)) {
            self.block = block
        }
    }
    
    func dispatch_get_global_queue(_ queueId: Int, _ arg: Int) -> Int { return 0 }
    
    func dispatch_async(_ queueId: Int, _ block: (Void -> Void)) {
        let unmanagedDispatchContext = Unmanaged.passRetained(dispatch_context(block))
        let context = UnsafeMutablePointer<Void>(OpaquePointer(bitPattern: unmanagedDispatchContext))
        var pthread: pthread_t = 0
        pthread_create(&pthread, nil, { (context: UnsafeMutablePointer<Void>!) -> UnsafeMutablePointer<Void>! in
            let unmanaged = Unmanaged<dispatch_context>.fromOpaque(OpaquePointer(context))
            unmanaged.takeUnretainedValue().block()
            unmanaged.release()
            return context
            }, context)
    }
    
#endif
