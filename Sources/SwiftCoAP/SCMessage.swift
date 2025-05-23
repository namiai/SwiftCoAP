//
//  SCMessage.swift
//  SwiftCoAP
//
//  Created by Wojtek Kordylewski on 22.04.15.
//  Copyright (c) 2015 Wojtek Kordylewski. All rights reserved.
//

import Foundation
import Network
import os.log

// MARK: - SC Coap Transport Layer Error Enumeration

public enum SCCoAPTransportLayerError: Error {
    case setupError(errorDescription: String), sendError(errorDescription: String), encodeError, pingTimeoutError
}

// MARK: - SC CoAP Transport Layer Delegate Protocol declaration. It is implemented by SCClient to receive responses. Your custom transport layer handler must call these callbacks to notify the SCClient object.

public protocol SCCoAPTransportLayerDelegate {
    // CoAP Data Received
    func transportLayerObject(_ transportLayerObject: SCCoAPTransportLayerProtocol, didReceiveData data: Data, fromHost host: String, port: UInt16)
    func transportLayerObject(_ transportLayerObject: SCCoAPTransportLayerProtocol, didReceiveData data: Data, fromEndpoint endpoint: NWEndpoint)

    // Error occured. Provide an appropriate NSError object.
    func transportLayerObject(_ transportLayerObject: SCCoAPTransportLayerProtocol, didFailWithError error: NSError)
}

public extension SCCoAPTransportLayerDelegate {
    func transportLayerObject(_ transportLayerObject: SCCoAPTransportLayerProtocol, didReceiveData data: Data, fromHost host: String, port: UInt16) {
        self.transportLayerObject(transportLayerObject, didReceiveData: data, fromEndpoint: NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        ))
    }
}

// MARK: - SC CoAP Transport Layer Protocol declaration

public protocol SCCoAPTransportLayerProtocol {
    // `SClient` calls one of the following methods when it wants to send CoAP data.
    //
    // Only a `sendCoAPData(_ data: Data, toEndpoint endpoint: NWEndpoint)` should be implemented.
    // A method `sendCoAPData(_ data: Data, toHost host: String, port: UInt16)` has the default implementation in protocol extension
    // just converting `host` and `port` into an `NWEndpoint` object.
    func sendCoAPMessage(_ message: SCMessage, toEndpoint endpoint: NWEndpoint, token: UInt64?, delegate: SCCoAPTransportLayerDelegate?) throws

    func getMessageId(for endpoint: NWEndpoint) -> UInt16
    func cancelMessageTransmission(to endpoint: NWEndpoint, withToken: UInt64)
    // Closes all connections to the endpoints
    func cancelConnection(to endpoint: NWEndpoint)
    func closeAllTransmissions()
}

public struct MessageTransportIdentifier: Equatable, Hashable {
    let token: UInt64
    let endpoint: NWEndpoint
}

public struct MessageTransportDelegate {
    let delegate: SCCoAPTransportLayerDelegate
    let observation: Bool
}

public struct CoAPConnection {
    let connection: NWConnection
    var lastReceivedMessageTs: TimeInterval
    var pingTimer: Timer?
}

// MARK: - SC CoAP UDP Transport Layer

/// SC CoAP UDP Transport Layer: This class is the default transport layer handler, sending data via UDP with help of `Network.framework`. If you want to create a custom transport layer handler, you have to create a custom class and adopt the SCCoAPTransportLayerProtocol. Next you have to pass your class to the init method of SCClient: init(delegate: SCClientDelegate?, transportLayerObject: SCCoAPTransportLayerProtocol). You will than get callbacks to send CoAP data and have to inform your delegate (in this case an object of type SCClient) when you receive a response by using the callbacks from SCCoAPTransportLayerDelegate.
public final class SCCoAPUDPTransportLayer {
    internal let kPingInterval: TimeInterval = 1.5
    internal var transportLayerDelegates: [MessageTransportIdentifier: MessageTransportDelegate] = [:]
    internal var connections: [NWEndpoint: CoAPConnection] = [:]
    internal var messageIdsPerEndpoint: [NWEndpoint: UInt16] = [:]
    internal var listener: NWListener?
    internal var networkParameters: NWParameters = .udp
    private var establishingConnectionTimeoutTimer: Timer? = nil
    internal let operationsQueue = DispatchQueue(label: "swiftcoap.queue.operations", qos: .default)

    public required init() {}

    internal func setupStateUpdateHandler(for connection: NWConnection) -> NWConnection {
        let endpoint = connection.endpoint
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case let .failed(error):
                os_log("Connection to ENDPOINT %@ FAILED", log: .default, type: .error, "\(error)", endpoint.debugDescription)
                guard let self = self else { return }
                self.transportLayerDelegates.forEach { $0.value.delegate.transportLayerObject(self, didFailWithError: error as NSError) }
                self.cancelConnection(to: endpoint)
            case .setup:
                os_log("Connection to ENDPOINT %@ entered SETUP state", log: .default, type: .info, endpoint.debugDescription)
            case let .waiting(reason):
                os_log("Connection to ENDPOINT %@ entered WAITING state. Reason %@", log: .default, type: .info, endpoint.debugDescription, reason.debugDescription)
            case .preparing:
                os_log("Connection to ENDPOINT %@ entered PREPAIRING state", log: .default, type: .info, endpoint.debugDescription)
                // sometimes the connection gets stuck in the "preparing" state
                // that happened when the device was discoverable on the local network (via bonjour) but it
                // was in different, isolated network from the phone
                // Even when changing the Wi-Fi connection to the same network as the devices
                // the connection never exited the "preparing" state.
                // This timer makes sure we fail the connection and let upper layers to retry
                let establishingConnectionTimeoutTimer = Timer(timeInterval: 2, repeats: false, block: { [weak self] _ in
                    guard let self = self else { return }
                    self.transportLayerDelegates.forEach { $0.value.delegate.transportLayerObject(self, didFailWithError: NSError(domain: SCMessage.kCoapErrorDomain, code: -1001)) }
                    self.cancelConnection(to: endpoint)
                })
                RunLoop.main.add(establishingConnectionTimeoutTimer, forMode: .default)
                self?.establishingConnectionTimeoutTimer = establishingConnectionTimeoutTimer
            case .ready:
                os_log("Connection to ENDPOINT %@ entered READY state", log: .default, type: .info, endpoint.debugDescription)
                guard let self = self else { return }
                self.establishingConnectionTimeoutTimer?.invalidate()
                self.handleReadyState(forEndpoint: endpoint, connection: connection)
            case .cancelled:
                os_log("Connection to ENDPOINT %@ is CANCELLED", log: .default, type: .info, endpoint.debugDescription)
                guard let self = self else { return }
                self.cancelConnection(to: endpoint)
            @unknown default:
                os_log("Connection to ENDPOINT %@ is in UNKNOWN state", log: .default, type: .info, endpoint.debugDescription)
            }
        }
        return connection
    }

    internal func handleReadyState(forEndpoint endpoint: NWEndpoint, connection: NWConnection) {
        let pingTimer = Timer(timeInterval: kPingInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            self.processPingTimer(timer: timer, endpoint: endpoint)
        }
        operationsQueue.async { [weak self] in
            self?.connections[connection.endpoint]?.pingTimer = pingTimer
        }
        // timer should be added to the runloop different from current one,
        // it seems that the runloop powering state update handler prevents timers to fire
        RunLoop.main.add(pingTimer, forMode: .default)

        startReads(from: connection)
    }

    internal func mustGetConnection(forEndpoint endpoint: NWEndpoint) -> NWConnection {
        let connectionKey = endpoint
        // Reuse only connections in untroubled state
        if let coapConnection = connections[connectionKey], coapConnection.connection.state != .cancelled {
            return coapConnection.connection
        }
        // Setup handler and start the new connection
        let connection = setupStateUpdateHandler(for: NWConnection(to: endpoint, using: networkParameters))

        operationsQueue.async { [weak self] in
            self?.connections[connectionKey] = CoAPConnection(connection: connection, lastReceivedMessageTs: Date().timeIntervalSince1970, pingTimer: nil)
        }
        connection.start(queue: DispatchQueue.global(qos: .default))
        return connection
    }

    internal func startReads(from connection: NWConnection) {
        guard connection.state == .ready else {
            return
        }

        connection.receiveMessage { [weak self] data, _, _, maybeError in
            guard let self = self else {
                connection.cancel()
                return
            }
            if let error = maybeError {
                if error != NWError.posix(.ECANCELED) {
                    self.notifyDelegatesAboutError(for: connection.endpoint, error: error)
                }
                self.cancelConnection(to: connection.endpoint)
                return
            }
            if let data = data {
                if let message = SCMessage.fromData(data) {
                    self.handleReceivedMessage(message, connection: connection, rawData: data)
                }
            }
            self.startReads(from: connection)
        }
    }

    internal func handleReceivedMessage(_ message: SCMessage, connection: NWConnection, rawData: Data) {
        // Send confirmation if message is confirmable
        let token = message.token
        updateMessageId(for: connection.endpoint, newMessageId: message.messageId)
        updateLastReceivedMessageTs(for: connection.endpoint)
        os_log(">>> %@", log: .default, type: .debug, "Endpoint: \(connection.endpoint.debugDescription), Message \(message.toString())")

        let id = MessageTransportIdentifier(token: token, endpoint: connection.endpoint)

        // if we received confirmable message nobody was expecting, send the reset command to stop observations
        /*
         https://datatracker.ietf.org/doc/html/rfc7641#section-3.5
         If a client does not recognize the token in a confirmable
         notification, it MUST NOT acknowledge the message and SHOULD reject
         it with a Reset message; otherwise, the client MUST acknowledge the
         message as usual.  In the case of a non-confirmable notification,
         rejecting the message with a Reset message is OPTIONAL.
         */
        if message.type == .confirmable, transportLayerDelegates[id] == nil {
            sendEmptyMessageWithType(.reset, messageId: message.messageId, token: nil, toEndpoint: connection.endpoint)
            return
        }

        if message.type == .confirmable {
            sendEmptyMessageWithType(.acknowledgement, messageId: message.messageId, token: nil, toEndpoint: connection.endpoint)
        }
        if let delegate = transportLayerDelegates[id] {
            delegate.delegate.transportLayerObject(self, didReceiveData: rawData, fromEndpoint: connection.endpoint)
            if delegate.observation == false, message.type == .acknowledgement {
                operationsQueue.sync { [weak self] in
                    _ = self?.transportLayerDelegates.removeValue(forKey: id)
                }
            }
        }
    }

    internal func sendEmptyMessageWithType(_ type: SCType, messageId: UInt16, token: UInt64?, toEndpoint endpoint: NWEndpoint) {
        let emptyMessage = SCMessage()
        emptyMessage.type = type
        emptyMessage.messageId = messageId
        emptyMessage.token = token ?? 0
        try? sendCoAPMessage(emptyMessage, toEndpoint: endpoint, token: token, delegate: nil)
    }

    internal func updateMessageId(for endpoint: NWEndpoint, newMessageId: UInt16) {
        operationsQueue.async { [weak self] in
            self?.messageIdsPerEndpoint[endpoint] = newMessageId
        }
    }

    internal func updateLastReceivedMessageTs(for endpoint: NWEndpoint) {
        operationsQueue.async { [weak self] in
            self?.connections[endpoint]?.lastReceivedMessageTs = Date().timeIntervalSince1970
        }
    }

    internal func notifyDelegatesAboutError(for endpoint: NWEndpoint, error: Error) {
        transportLayerDelegates.forEach { key, value in
            if key.endpoint == endpoint {
                value.delegate.transportLayerObject(self, didFailWithError: error as NSError)
            }
        }
    }

    internal func processPingTimer(timer: Timer, endpoint: NWEndpoint) {
        operationsQueue.async { [weak self] in
            guard let self = self, let coapConnection = self.connections[endpoint] else {
                timer.invalidate()
                return
            }
            
            guard coapConnection.connection.state != .cancelled else {
                timer.invalidate()
                return
            }
            
            DispatchQueue.main.async {
                self.handlePingTimer(with: timer, endpoint: endpoint, connection: coapConnection)
            }
        }
        
    }
    
    internal func handlePingTimer(with timer: Timer, endpoint: NWEndpoint, connection coapConnection: CoAPConnection) {
        // if there were no messages for 3*ping intervals -> connection is stale and probably broken
        // The best we can do in this situation is to cancel the connection and let upper levels
        // decide what to do
        if coapConnection.lastReceivedMessageTs + kPingInterval * 3 < Date().timeIntervalSince1970 {
            os_log("Ping timeout exceeded, closing the connection for endpoint %@", log: .default, type: .info, endpoint.debugDescription)
            notifyDelegatesAboutError(for: endpoint, error: SCCoAPTransportLayerError.pingTimeoutError)
            cancelConnection(to: endpoint)
            return
        }
        // if the most recent message was received within a duration of keep-alive interval then
        // we need to extend the timer to get the full interval of inactivity
        let elapsedFromLastMessage = floor(Date().timeIntervalSince1970 - coapConnection.lastReceivedMessageTs)
        if elapsedFromLastMessage < kPingInterval {
            coapConnection.pingTimer?.fireDate = Date().addingTimeInterval(kPingInterval - elapsedFromLastMessage)
        } else {
            os_log("Sending ping message to endpoint %@", log: .default, type: .debug, endpoint.debugDescription)
            /*

             Reset Message
             A Reset message indicates that a specific message (Confirmable or
             Non-confirmable) was received, but some context is missing to
             properly process it.  This condition is usually caused when the
             receiving node has rebooted and has forgotten some state that
             would be required to interpret the message.  Provoking a Reset
             message (e.g., by sending an Empty Confirmable message) is also
             useful as an inexpensive check of the liveness of an endpoint
             ("CoAP ping").

             */
            sendEmptyMessageWithType(.confirmable, messageId: getMessageId(for: endpoint), token: nil, toEndpoint: endpoint)
            // +1 here to give the message time to go to the device and back and avoid timer firing too early
            coapConnection.pingTimer?.fireDate = Date().addingTimeInterval(kPingInterval + 1)
        }
    }
}

extension SCCoAPUDPTransportLayer: SCCoAPTransportLayerProtocol {
    /// Passing a PSK to init sets all NWConnection and NWListener objects if any created
    /// to use DTLS with provided PSK.
    /// - Parameter psk: A Preshared Key in plain text form.
    /// - Parameter suite: A cipher suite to be used for TLS communications, defaults to `TLS_PSK_WITH_AES_128_GCM_SHA256` when not specified.
    public convenience init?(psk: String, suite: SSLCipherSuite = TLS_PSK_WITH_AES_128_GCM_SHA256) {
        guard let psk = psk.data(using: .utf8) else { return nil }
        self.init(psk: psk, suite: suite)
    }

    /// Passing a PSK to init sets all NWConnection and NWListener objects if any created
    /// to use DTLS with provided PSK.
    /// - Parameter psk: A Preshared Key.
    /// - Parameter suite: A cipher suite to be used for TLS communications, defaults to `TLS_PSK_WITH_AES_128_GCM_SHA256` when not specified.
    public convenience init(psk: Data, suite: SSLCipherSuite = TLS_PSK_WITH_AES_128_GCM_SHA256) {
        self.init()
        networkParameters = networkParametersDTLSWith(psk: psk, suite: suite)
    }

    /// NWParameters to use with all NWConnection and NWListener objects if any created.
    /// Helps to customize transport layer behaviour with non-standard connection options.
    /// E.g. setting certificate chalange, verifiction handlers for connections etc.
    /// - Parameter networkParameters: A `NWParameters` object holding all the custom setup
    /// to be passed to `NWConnection` or `NWListener` if any.
    public convenience init(networkParameters: NWParameters) {
        self.init()
        self.networkParameters = networkParameters
    }

    /// Retrieves new message id for endpoint
    /// There could be multiple clients using the same underlying transport, so it's important to have centralized
    /// message ids issuance
    public func getMessageId(for endpoint: NWEndpoint) -> UInt16 {
        operationsQueue.sync { [weak self] in
            guard let self = self else { return 0 }
            if let currentMessageId = self.messageIdsPerEndpoint[endpoint] {
                let newMessageId = (currentMessageId % 0xFFFF) + 1
                self.messageIdsPerEndpoint[endpoint] = newMessageId
                return newMessageId
            } else {
                let newMessageId = UInt16(arc4random_uniform(0xFFFF))
                self.messageIdsPerEndpoint[endpoint] = newMessageId
                return newMessageId
            }
        }
    }

    public func sendCoAPMessage(_ message: SCMessage, toEndpoint endpoint: NWEndpoint, token: UInt64?, delegate: SCCoAPTransportLayerDelegate?) throws {
        guard let data = message.toData() else { throw SCCoAPTransportLayerError.encodeError }
        guard let connection = operationsQueue.sync(execute: { [weak self] () -> NWConnection? in
            guard let self = self else { return nil }
            if let delegate = delegate, let token = token {
                self.transportLayerDelegates[MessageTransportIdentifier(token: token, endpoint: endpoint)] = MessageTransportDelegate(delegate: delegate, observation: message.isObservation())
            }
            return self.mustGetConnection(forEndpoint: endpoint)
        }) else { return }
        os_log("<<< %@", log: .default, type: .debug, "Endpoint: \(endpoint.debugDescription), Message \(message.toString())")
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if error != nil {
                delegate?.transportLayerObject(self, didFailWithError: error! as NSError)
                if let token = token {
                    self.cancelMessageTransmission(to: endpoint, withToken: token)
                }
            }
        })
    }

    public func cancelMessageTransmission(to endpoint: NWEndpoint, withToken token: UInt64) {
        _ = operationsQueue.async { [weak self] in
            self?.transportLayerDelegates.removeValue(forKey: MessageTransportIdentifier(token: token, endpoint: endpoint))
        }
    }

    public func closeAllTransmissions() {
        let allEndpoints = connections.keys
        for endpoint in allEndpoints {
            cancelConnection(to: endpoint)
        }
    }

    private func networkParametersDTLSWith(psk: Data, suite: SSLCipherSuite) -> NWParameters {
        NWParameters(dtls: tlsWithPSKOptions(psk: psk, suite: suite), udp: NWProtocolUDP.Options())
    }

    private func tlsWithPSKOptions(psk: Data, suite: SSLCipherSuite) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let semaphore = DispatchSemaphore(value: 0)
        psk.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            defer { semaphore.signal() }
            let dd = DispatchData(bytes: pointer)
            let hint = DispatchData(bytes: "".data(using: .utf8)!.withUnsafeBytes { $0 })
            sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, dd as __DispatchData, hint as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(suite))!)
        }
        semaphore.wait()
        return tlsOptions
    }

    public func cancelConnection(to endpoint: NWEndpoint) {
        operationsQueue.async { [weak self] in
            guard let self = self else { return }
            if let coapConnection = self.connections[endpoint] {
                coapConnection.pingTimer?.invalidate()
                coapConnection.connection.cancel()
                let delegates = self.transportLayerDelegates.keys.filter { $0.endpoint == endpoint }
                for delegate in delegates {
                    self.transportLayerDelegates.removeValue(forKey: delegate)
                }
            }
            self.connections.removeValue(forKey: endpoint)
        }
    }
}

// MARK: - SC Type Enumeration: Represents the CoAP types

public enum SCType: Int {
    case confirmable, nonConfirmable, acknowledgement, reset

    public func shortString() -> String {
        switch self {
        case .confirmable:
            return "CON"
        case .nonConfirmable:
            return "NON"
        case .acknowledgement:
            return "ACK"
        case .reset:
            return "RST"
        }
    }

    public func longString() -> String {
        switch self {
        case .confirmable:
            return "Confirmable"
        case .nonConfirmable:
            return "Non Confirmable"
        case .acknowledgement:
            return "Acknowledgement"
        case .reset:
            return "Reset"
        }
    }

    public static func fromShortString(_ string: String) -> SCType? {
        switch string.uppercased() {
        case "CON":
            return .confirmable
        case "NON":
            return .nonConfirmable
        case "ACK":
            return .acknowledgement
        case "RST":
            return .reset
        default:
            return nil
        }
    }
}

// MARK: - SC Option Enumeration: Represents the CoAP options

public enum SCOption: Int {
    case ifMatch = 1
    case uriHost = 3
    case etag = 4
    case ifNoneMatch = 5
    case observe = 6
    case uriPort = 7
    case locationPath = 8
    case uriPath = 11
    case contentFormat = 12
    case maxAge = 14
    case uriQuery = 15
    case accept = 17
    case locationQuery = 20
    case block2 = 23
    case block1 = 27
    case size2 = 28
    case proxyUri = 35
    case proxyScheme = 39
    case size1 = 60

    static let allValues = [ifMatch, uriHost, etag, ifNoneMatch, observe, uriPort, locationPath, uriPath, contentFormat, maxAge, uriQuery, accept, locationQuery, block2, block1, size2, proxyUri, proxyScheme, size1]

    public enum Format: Int {
        case empty, opaque, uInt, string
    }

    public func toString() -> String {
        switch self {
        case .ifMatch:
            return "If_Match"
        case .uriHost:
            return "URI_Host"
        case .etag:
            return "ETAG"
        case .ifNoneMatch:
            return "If_None_Match"
        case .observe:
            return "Observe"
        case .uriPort:
            return "URI_Port"
        case .locationPath:
            return "Location_Path"
        case .uriPath:
            return "URI_Path"
        case .contentFormat:
            return "Content_Format"
        case .maxAge:
            return "Max_Age"
        case .uriQuery:
            return "URI_Query"
        case .accept:
            return "Accept"
        case .locationQuery:
            return "Location_Query"
        case .block2:
            return "Block2"
        case .block1:
            return "Block1"
        case .size2:
            return "Size2"
        case .proxyUri:
            return "Proxy_URI"
        case .proxyScheme:
            return "Proxy_Scheme"
        case .size1:
            return "Size1"
        }
    }

    public static func isNumberCritical(_ optionNo: Int) -> Bool {
        return optionNo % 2 == 1
    }

    public func isCritical() -> Bool {
        return SCOption.isNumberCritical(rawValue)
    }

    public static func isNumberUnsafe(_ optionNo: Int) -> Bool {
        return optionNo & 0b10 == 0b10
    }

    public func isUnsafe() -> Bool {
        return SCOption.isNumberUnsafe(rawValue)
    }

    public static func isNumberNoCacheKey(_ optionNo: Int) -> Bool {
        return optionNo & 0b11110 == 0b11100
    }

    public func isNoCacheKey() -> Bool {
        return SCOption.isNumberNoCacheKey(rawValue)
    }

    public static func isNumberRepeatable(_ optionNo: Int) -> Bool {
        switch optionNo {
        case SCOption.ifMatch.rawValue, SCOption.etag.rawValue, SCOption.locationPath.rawValue, SCOption.uriPath.rawValue, SCOption.uriQuery.rawValue, SCOption.locationQuery.rawValue:
            return true
        default:
            return false
        }
    }

    public func isRepeatable() -> Bool {
        return SCOption.isNumberRepeatable(rawValue)
    }

    public func format() -> Format {
        switch self {
        case .ifNoneMatch:
            return .empty
        case .ifMatch, .etag:
            return .opaque
        case .uriHost, .locationPath, .uriPath, .uriQuery, .locationQuery, .proxyUri, .proxyScheme:
            return .string
        default:
            return .uInt
        }
    }

    public func dataForValueString(_ valueString: String) -> Data? {
        return SCOption.dataForOptionValueString(valueString, format: format())
    }

    public static func dataForOptionValueString(_ valueString: String, format: Format) -> Data? {
        switch format {
        case .empty:
            return nil
        case .opaque:
            return Data.fromOpaqueString(valueString)
        case .string:
            return valueString.data(using: String.Encoding.utf8)
        case .uInt:
            if let number = UInt(valueString) {
                var byteArray = number.toByteArray()
                return Data(bytes: &byteArray, count: byteArray.count)
            }
            return nil
        }
    }

    public func displayStringForData(_ data: Data?) -> String {
        return SCOption.displayStringForFormat(format(), data: data)
    }

    public static func displayStringForFormat(_ format: Format, data: Data?) -> String {
        switch format {
        case .empty:
            return "< Empty >"
        case .opaque:
            if let valueData = data {
                return String.toHexFromData(valueData)
            }
            return "0x0"
        case .uInt:
            if let valueData = data {
                return String(UInt.fromData(valueData))
            }
            return "0"
        case .string:
            if let valueData = data, let string = NSString(data: valueData, encoding: String.Encoding.utf8.rawValue) as String? {
                return string
            }
            return "<<Format Error>>"
        }
    }
}

// MARK: - SC Code Sample Enumeration: Provides the most common CoAP codes as raw values

public enum SCCodeSample: Int {
    case empty = 0
    case get = 1
    case post = 2
    case put = 3
    case delete = 4
    case created = 65
    case deleted = 66
    case valid = 67
    case changed = 68
    case content = 69
    case `continue` = 95
    case badRequest = 128
    case unauthorized = 129
    case badOption = 130
    case forbidden = 131
    case notFound = 132
    case methodNotAllowed = 133
    case notAcceptable = 134
    case requestEntityIncomplete = 136
    case preconditionFailed = 140
    case requestEntityTooLarge = 141
    case unsupportedContentFormat = 143
    case internalServerError = 160
    case notImplemented = 161
    case badGateway = 162
    case serviceUnavailable = 163
    case gatewayTimeout = 164
    case proxyingNotSupported = 165

    public func codeValue() -> SCCodeValue! {
        return SCCodeValue.fromCodeSample(self)
    }

    public func toString() -> String {
        switch self {
        case .empty:
            return "Empty"
        case .get:
            return "Get"
        case .post:
            return "Post"
        case .put:
            return "Put"
        case .delete:
            return "Delete"
        case .created:
            return "Created"
        case .deleted:
            return "Deleted"
        case .valid:
            return "Valid"
        case .changed:
            return "Changed"
        case .content:
            return "Content"
        case .continue:
            return "Continue"
        case .badRequest:
            return "Bad Request"
        case .unauthorized:
            return "Unauthorized"
        case .badOption:
            return "Bad Option"
        case .forbidden:
            return "Forbidden"
        case .notFound:
            return "Not Found"
        case .methodNotAllowed:
            return "Method Not Allowed"
        case .notAcceptable:
            return "Not Acceptable"
        case .requestEntityIncomplete:
            return "Request Entity Incomplete"
        case .preconditionFailed:
            return "Precondition Failed"
        case .requestEntityTooLarge:
            return "Request Entity Too Large"
        case .unsupportedContentFormat:
            return "Unsupported Content Format"
        case .internalServerError:
            return "Internal Server Error"
        case .notImplemented:
            return "Not Implemented"
        case .badGateway:
            return "Bad Gateway"
        case .serviceUnavailable:
            return "Service Unavailable"
        case .gatewayTimeout:
            return "Gateway Timeout"
        case .proxyingNotSupported:
            return "Proxying Not Supported"
        }
    }

    public static func stringFromCodeValue(_ codeValue: SCCodeValue) -> String? {
        return codeValue.toCodeSample()?.toString()
    }
}

// MARK: - SC Content Format Enumeration

public enum SCContentFormat: UInt {
    case plain = 0
    case linkFormat = 40
    case xml = 41
    case octetStream = 42
    case exi = 47
    case json = 50
    case cbor = 60

    public func needsStringUTF8Conversion() -> Bool {
        switch self {
        case .octetStream, .exi, .cbor:
            return false
        default:
            return true
        }
    }

    public func toString() -> String {
        switch self {
        case .plain:
            return "Plain"
        case .linkFormat:
            return "Link Format"
        case .xml:
            return "XML"
        case .octetStream:
            return "Octet Stream"
        case .exi:
            return "EXI"
        case .json:
            return "JSON"
        case .cbor:
            return "CBOR"
        }
    }
}

// MARK: - SC Code Value struct: Represents the CoAP code. You can easily apply the CoAP code syntax c.dd (e.g. SCCodeValue(classValue: 0, detailValue: 01) equals 0.01)

public struct SCCodeValue: Equatable {
    let classValue: UInt8
    let detailValue: UInt8

    public init(rawValue: UInt8) {
        let firstBits: UInt8 = rawValue >> 5
        let lastBits: UInt8 = rawValue & 0b0001_1111
        classValue = firstBits
        detailValue = lastBits
    }

    // classValue must not be larger than 7; detailValue must not be larger than 31
    public init?(classValue: UInt8, detailValue: UInt8) {
        if classValue > 0b111 || detailValue > 0b11111 { return nil }

        self.classValue = classValue
        self.detailValue = detailValue
    }

    public func toRawValue() -> UInt8 {
        return classValue << 5 + detailValue
    }

    public func toCodeSample() -> SCCodeSample? {
        return SCCodeSample(rawValue: Int(toRawValue()))
    }

    public static func fromCodeSample(_ code: SCCodeSample) -> SCCodeValue {
        return SCCodeValue(rawValue: UInt8(code.rawValue))
    }

    public func toString() -> String {
        return String(format: "%i.%02d", classValue, detailValue)
    }

    public func requestString() -> String? {
        switch self {
        case SCCodeValue(classValue: 0, detailValue: 01)!:
            return "GET"
        case SCCodeValue(classValue: 0, detailValue: 02)!:
            return "POST"
        case SCCodeValue(classValue: 0, detailValue: 03)!:
            return "PUT"
        case SCCodeValue(classValue: 0, detailValue: 04)!:
            return "DELETE"
        default:
            return nil
        }
    }
}

public func == (lhs: SCCodeValue, rhs: SCCodeValue) -> Bool {
    return lhs.classValue == rhs.classValue && lhs.detailValue == rhs.detailValue
}

// MARK: - UInt Extension

public extension UInt {
    func toByteArray() -> [UInt8] {
        let byteLength = UInt(ceil(log2(Double(self + 1)) / 8))
        var byteArray = [UInt8]()
        for i: UInt in 0 ..< byteLength {
            byteArray.append(UInt8((self >> ((byteLength - i - 1) * 8)) & 0xFF))
        }
        return byteArray
    }

    static func fromData(_ data: Data) -> UInt {
        var valueBytes = [UInt8](repeating: 0, count: data.count)
        (data as NSData).getBytes(&valueBytes, length: data.count)

        var actualValue: UInt = 0
        for i in 0 ..< valueBytes.count {
            actualValue += UInt(valueBytes[i]) << ((UInt(valueBytes.count) - UInt(i + 1)) * 8)
        }
        return actualValue
    }
}

// MARK: - String Extension

extension String {
    static func toHexFromData(_ data: Data) -> String {
        let string = data.description.replacingOccurrences(of: " ", with: "")
        return "0x" + string[string.index(string.startIndex, offsetBy: 1) ..< string.index(string.endIndex, offsetBy: -1)]
    }
}

// MARK: - NSData Extension

extension Data {
    static func fromOpaqueString(_ string: String) -> Data? {
        let comps = string.components(separatedBy: "x")
        if let lastString = comps.last, let number = UInt(lastString, radix: 16), comps.count <= 2 {
            var byteArray = number.toByteArray()
            return Data(bytes: &byteArray, count: byteArray.count)
        }
        return nil
    }
}

// MARK: - SC Allowed Route Enumeration

public enum SCAllowedRoute: UInt {
    case get = 0b1
    case post = 0b10
    case put = 0b100
    case delete = 0b1000

    public init?(codeValue: SCCodeValue) {
        switch codeValue {
        case SCCodeValue(classValue: 0, detailValue: 01)!:
            self = .get
        case SCCodeValue(classValue: 0, detailValue: 03)!:
            self = .post
        case SCCodeValue(classValue: 0, detailValue: 03)!:
            self = .put
        case SCCodeValue(classValue: 0, detailValue: 04)!:
            self = .delete
        default:
            return nil
        }
    }
}

// MARK: - Resource Implementation, used for SCServer

open class SCResourceModel: NSObject {
    public let name: String // Name of the resource
    public let allowedRoutes: UInt // Bitmask of allowed routes (see SCAllowedRoutes enum)
    public var maxAgeValue: UInt! // If not nil, every response will contain the provided MaxAge value
    fileprivate(set) var etag: Data! // If not nil, every response to a GET request will contain the provided eTag. The etag is generated automatically whenever you update the dataRepresentation of the resource
    public var dataRepresentation: Data! {
        didSet {
            if var hashInt = dataRepresentation?.hashValue {
                etag = Data(bytes: &hashInt, count: MemoryLayout<Int>.size)
            } else {
                etag = nil
            }
        }
    } // The current data representation of the resource. Needs to stay up to date
    public var observable = false // If true, a response will contain the Observe option, and endpoints will be able to register as observers in SCServer. Call updateRegisteredObserversForResource(self), anytime your dataRepresentation changes.

    // Desigated initializer
    public init(name: String, allowedRoutes: UInt) {
        self.name = name
        self.allowedRoutes = allowedRoutes
    }

    // The Methods for Data reception for allowed routes. SCServer will call the appropriate message upon the reception of a reqeuest. Override the respective methods, which match your allowedRoutes.
    // SCServer passes a queryDictionary containing the URI query content (e.g ["user_id": "23"]) and all options contained in the respective request. The POST and PUT methods provide the message's payload as well.
    // Refer to the example resources in the SwiftCoAPServerExample project for implementation examples.

    // This method lets you decide whether the current request shall be processed asynchronously, i.e. if true will be returned, an empty ACK will be sent, and you can provide the actual response by calling the servers "didCompleteAsynchronousRequestForOriginalMessage(...)". Note: "dataForGet", "dataForPost", etc. will not be called additionally if you return true.
    open func willHandleDataAsynchronouslyForRoute(_: SCAllowedRoute, queryDictionary _: [String: String], options _: [Int: [Data]], originalMessage _: SCMessage) -> Bool { return false }

    // The following methods require data for the given routes GET, POST, PUT, DELETE and must be overriden if needed. If you return nil, the server will respond with a "Method not allowed" error code (Make sure that you have set the allowed routes in the "allowedRoutes" bitmask property).
    // You have to return a tuple with a statuscode, optional payload, optional content format for your provided payload and (in case of POST and PUT) an optional locationURI.
    open func dataForGet(queryDictionary _: [String: String], options _: [Int: [Data]]) -> (statusCode: SCCodeValue, payloadData: Data?, contentFormat: SCContentFormat?)? { return nil }
    open func dataForPost(queryDictionary _: [String: String], options _: [Int: [Data]], requestData _: Data?) -> (statusCode: SCCodeValue, payloadData: Data?, contentFormat: SCContentFormat?, locationUri: String?)? { return nil }
    open func dataForPut(queryDictionary _: [String: String], options _: [Int: [Data]], requestData _: Data?) -> (statusCode: SCCodeValue, payloadData: Data?, contentFormat: SCContentFormat?, locationUri: String?)? { return nil }
    open func dataForDelete(queryDictionary _: [String: String], options _: [Int: [Data]]) -> (statusCode: SCCodeValue, payloadData: Data?, contentFormat: SCContentFormat?)? { return nil }
}

// MARK: - SC Message IMPLEMENTATION

public class SCMessage: NSObject {
    // MARK: Constants and Properties

    // CONSTANTS
    static let kCoapVersion = 0b01
    static let kProxyCoAPTypeKey = "COAP_TYPE"

    public static let kCoapErrorDomain = "SwiftCoapErrorDomain"
    static let kAckTimeout = 2.0
    static let kAckRandomFactor = 1.5
    static let kMaxRetransmit = 4
    static let kMaxTransmitWait = 93.0

    let kDefaultMaxAgeValue: UInt = 60
    let kOptionOneByteExtraValue: UInt8 = 13
    let kOptionTwoBytesExtraValue: UInt8 = 14

    // INTERNAL PROPERTIES (allowed to modify)

    public var code: SCCodeValue = .init(classValue: 0, detailValue: 0)! // Code value is Empty by default
    public var type: SCType = .confirmable // Type is CON by default
    public var payload: Data? // Add a payload (optional)
    public lazy var options = [Int: [Data]]() // CoAP-Options. It is recommend to use the addOption(..) method to add a new option.

    // The following properties are modified by SCClient/SCServer. Modification has no effect and is therefore not recommended
    public internal(set) var blockBody: Data? // Helper for Block1 tranmission. Used by SCClient, modification has no effect
    public internal(set) var endpoint: NWEndpoint?
    public internal(set) var resourceForConfirmableResponse: SCResourceModel?
    public internal(set) var messageId: UInt16!
    public internal(set) var token: UInt64 = 0

    var timeStamp: Date?

    // MARK: Internal Methods (allowed to use)

    public convenience init(code: SCCodeValue, type: SCType, payload: Data?) {
        self.init()
        self.code = code
        self.type = type
        self.payload = payload
    }

    public func equalForCachingWithMessage(_ message: SCMessage) -> Bool {
        if code == message.code, endpoint == message.endpoint {
            let firstSet = Set(options.keys)
            let secondSet = Set(message.options.keys)

            let exOr = firstSet.symmetricDifference(secondSet)

            for optNo in exOr {
                if !(SCOption.isNumberNoCacheKey(optNo)) { return false }
            }

            let interSect = firstSet.intersection(secondSet)

            for optNo in interSect {
                if !(SCOption.isNumberNoCacheKey(optNo)), !(SCMessage.compareOptionValueArrays(options[optNo]!, second: message.options[optNo]!)) { return false }
            }
            return true
        }
        return false
    }

    public static func compareOptionValueArrays(_ first: [Data], second: [Data]) -> Bool {
        if first.count != second.count { return false }

        for i in 0 ..< first.count {
            if first[i] != second[i] { return false }
        }

        return true
    }

    public static func copyFromMessage(_ message: SCMessage) -> SCMessage {
        let copiedMessage = SCMessage(code: message.code, type: message.type, payload: message.payload)
        copiedMessage.options = message.options
        copiedMessage.endpoint = message.endpoint
        copiedMessage.messageId = message.messageId
        copiedMessage.token = message.token
        copiedMessage.timeStamp = message.timeStamp
        return copiedMessage
    }

    public func isFresh() -> Bool {
        func validateMaxAge(_ value: UInt) -> Bool {
            if let tStamp = timeStamp {
                let expirationDate = tStamp.addingTimeInterval(Double(value))
                return Date().compare(expirationDate) != .orderedDescending
            }
            return false
        }

        if let maxAgeValues = options[SCOption.maxAge.rawValue], let firstData = maxAgeValues.first {
            return validateMaxAge(UInt.fromData(firstData))
        }

        return validateMaxAge(kDefaultMaxAgeValue)
    }

    public func addOption(_ option: Int, data: Data) {
        if var currentOptionValue = options[option] {
            currentOptionValue.append(data)
            options[option] = currentOptionValue
        } else {
            options[option] = [data]
        }
    }

    public func toData() -> Data? {
        var resultData: NSMutableData

        let tokenLength = Int(ceil(log2(Double(token + 1)) / 8))
        if tokenLength > 8 {
            return nil
        }
        let codeRawValue = code.toRawValue()
        let firstByte = UInt8((SCMessage.kCoapVersion << 6) | (type.rawValue << 4) | tokenLength)
        let actualMessageId: UInt16 = messageId ?? 0
        var byteArray: [UInt8] = [firstByte, codeRawValue, UInt8(actualMessageId >> 8), UInt8(actualMessageId & 0xFF)]
        resultData = NSMutableData(bytes: &byteArray, length: byteArray.count)

        if tokenLength > 0 {
            var tokenByteArray = [UInt8]()
            for i in 0 ..< tokenLength {
                tokenByteArray.append(UInt8((token >> UInt64((tokenLength - i - 1) * 8)) & 0xFF))
            }
            resultData.append(&tokenByteArray, length: tokenLength)
        }

        let sortedOptions = options.sorted {
            $0.0 < $1.0
        }

        var previousDelta = 0
        for (key, valueArray) in sortedOptions {
            for value in valueArray {
                let optionDelta = key - previousDelta
                previousDelta += optionDelta

                var optionFirstByte: UInt8
                var extendedDelta: Data?
                var extendedLength: Data?

                if optionDelta >= Int(kOptionTwoBytesExtraValue) + 0xFF {
                    optionFirstByte = kOptionTwoBytesExtraValue << 4
                    let extendedDeltaValue = UInt16(optionDelta) - (UInt16(kOptionTwoBytesExtraValue) + 0xFF)
                    var extendedByteArray: [UInt8] = [UInt8(extendedDeltaValue >> 8), UInt8(extendedDeltaValue & 0xFF)]

                    extendedDelta = Data(bytes: &extendedByteArray, count: extendedByteArray.count)
                } else if optionDelta >= Int(kOptionOneByteExtraValue) {
                    optionFirstByte = kOptionOneByteExtraValue << 4
                    var extendedDeltaValue = UInt8(optionDelta) - kOptionOneByteExtraValue
                    extendedDelta = Data(bytes: &extendedDeltaValue, count: 1)
                } else {
                    optionFirstByte = UInt8(optionDelta) << 4
                }

                if value.count >= Int(kOptionTwoBytesExtraValue) + 0xFF {
                    optionFirstByte += kOptionTwoBytesExtraValue
                    let extendedLengthValue = UInt16(value.count) - (UInt16(kOptionTwoBytesExtraValue) + 0xFF)
                    var extendedByteArray: [UInt8] = [UInt8(extendedLengthValue >> 8), UInt8(extendedLengthValue & 0xFF)]

                    extendedLength = Data(bytes: &extendedByteArray, count: extendedByteArray.count)
                } else if value.count >= Int(kOptionOneByteExtraValue) {
                    optionFirstByte += kOptionOneByteExtraValue
                    var extendedLengthValue = UInt8(value.count) - kOptionOneByteExtraValue
                    extendedLength = Data(bytes: &extendedLengthValue, count: 1)
                } else {
                    optionFirstByte += UInt8(value.count)
                }

                resultData.append(&optionFirstByte, length: 1)
                if let extDelta = extendedDelta {
                    resultData.append(extDelta)
                }
                if let extLength = extendedLength {
                    resultData.append(extLength)
                }

                resultData.append(value)
            }
        }

        if let p = payload {
            var payloadMarker: UInt8 = 0xFF
            resultData.append(&payloadMarker, length: 1)
            resultData.append(p)
        }
        // print("resultData for Sending: \(resultData)")
        return resultData as Data
    }

    public static func fromData(_ data: Data) -> SCMessage? {
        if data.count < 4 { return nil }
        // print("parsing Message FROM Data: \(data)")
        // Unparse Header
        var parserIndex = 4
        var headerBytes = [UInt8](repeating: 0, count: parserIndex)
        (data as NSData).getBytes(&headerBytes, length: parserIndex)

        var firstByte = headerBytes[0]
        let tokenLenght = Int(firstByte) & 0xF
        firstByte >>= 4
        let type = SCType(rawValue: Int(firstByte) & 0b11)
        firstByte >>= 2
        guard tokenLenght <= 8,
              type != nil,
              firstByte == UInt8(kCoapVersion),
              (4 + tokenLenght) <= data.count // to exclude a crash on parsing invalid data
        else { return nil }

        // Assign header values to CoAP Message
        let message = SCMessage()
        message.type = type!
        message.code = SCCodeValue(rawValue: headerBytes[1])
        message.messageId = (UInt16(headerBytes[2]) << 8) + UInt16(headerBytes[3])

        if tokenLenght > 0 {
            var tokenByteArray = [UInt8](repeating: 0, count: tokenLenght)
            (data as NSData).getBytes(&tokenByteArray, range: NSMakeRange(4, tokenLenght))
            for i in 0 ..< tokenByteArray.count {
                message.token += UInt64(tokenByteArray[i]) << ((UInt64(tokenByteArray.count) - UInt64(i + 1)) * 8)
            }
        }
        parserIndex += tokenLenght

        var currentOptDelta = 0
        while parserIndex < data.count {
            var nextByte: UInt8 = 0
            (data as NSData).getBytes(&nextByte, range: NSMakeRange(parserIndex, 1))
            parserIndex += 1

            if nextByte == 0xFF {
                message.payload = data.subdata(in: parserIndex ..< data.count)
                break
            } else {
                let optLength = nextByte & 0xF
                nextByte >>= 4
                if nextByte == 0xF || optLength == 0xF { return nil }

                var finalDelta = 0
                switch nextByte {
                case 13:
                    (data as NSData).getBytes(&finalDelta, range: NSMakeRange(parserIndex, 1))
                    finalDelta += 13
                    parserIndex += 1
                case 14:
                    var twoByteArray = [UInt8](repeating: 0, count: 2)
                    (data as NSData).getBytes(&twoByteArray, range: NSMakeRange(parserIndex, 2))
                    finalDelta = (Int(twoByteArray[0]) << 8) + Int(twoByteArray[1])
                    finalDelta += (14 + 0xFF)
                    parserIndex += 2
                default:
                    finalDelta = Int(nextByte)
                }
                finalDelta += currentOptDelta
                currentOptDelta = finalDelta
                var finalLenght = 0
                switch optLength {
                case 13:
                    (data as NSData).getBytes(&finalLenght, range: NSMakeRange(parserIndex, 1))
                    finalLenght += 13
                    parserIndex += 1
                case 14:
                    var twoByteArray = [UInt8](repeating: 0, count: 2)
                    (data as NSData).getBytes(&twoByteArray, range: NSMakeRange(parserIndex, 2))
                    finalLenght = (Int(twoByteArray[0]) << 8) + Int(twoByteArray[1])
                    finalLenght += (14 + 0xFF)
                    parserIndex += 2
                default:
                    finalLenght = Int(optLength)
                }

                var optValue = Data()
                if finalLenght > 0 {
                    optValue = data.subdata(in: parserIndex ..< finalLenght + parserIndex)
                    parserIndex += finalLenght
                }
                message.addOption(finalDelta, data: optValue)
            }
        }

        return message
    }

    public func toHttpUrlRequestWithUrl() -> NSMutableURLRequest {
        let urlRequest = NSMutableURLRequest()
        if code != SCCodeSample.get.codeValue() {
            urlRequest.httpMethod = code.requestString()!
        }

        for (key, valueArray) in options {
            for value in valueArray {
                if let option = SCOption(rawValue: key) {
                    urlRequest.addValue(option.displayStringForData(value), forHTTPHeaderField: option.toString().uppercased())
                }
            }
        }
        urlRequest.httpBody = payload

        return urlRequest
    }

    public static func fromHttpUrlResponse(_ urlResponse: HTTPURLResponse, data: Data!) -> SCMessage {
        let message = SCMessage()
        message.payload = data
        message.code = SCCodeValue(rawValue: UInt8(urlResponse.statusCode & 0xFF))
        if let typeString = urlResponse.allHeaderFields[SCMessage.kProxyCoAPTypeKey] as? String, let type = SCType.fromShortString(typeString) {
            message.type = type
        } else {
            message.type = .acknowledgement
        }

        for opt in SCOption.allValues {
            if let optValue = urlResponse.allHeaderFields["HTTP_\(opt.toString().uppercased())"] as? String {
                let optValueData = opt.dataForValueString(optValue) ?? Data()
                message.options[opt.rawValue] = [optValueData]
            }
        }
        return message
    }

    public func completeUriPath() -> String {
        var finalPathString = ""
        if let pathDataArray = options[SCOption.uriPath.rawValue] {
            for i in 0 ..< pathDataArray.count {
                if let pathString = NSString(data: pathDataArray[i], encoding: String.Encoding.utf8.rawValue) {
                    if i > 0 { finalPathString += "/" }
                    finalPathString += String(pathString)
                }
            }
        }
        return finalPathString
    }

    public func uriQueryDictionary() -> [String: String] {
        var resultDict = [String: String]()
        if let queryDataArray = options[SCOption.uriQuery.rawValue] {
            for queryData in queryDataArray {
                if let queryString = NSString(data: queryData, encoding: String.Encoding.utf8.rawValue) {
                    let splitArray = queryString.components(separatedBy: "=")
                    if splitArray.count == 2 {
                        resultDict[splitArray.first!] = splitArray.last!
                    }
                }
            }
        }
        return resultDict
    }

    public static func getPathAndQueryDataArrayFromUriString(_ uriString: String) -> (pathDataArray: [Data], queryDataArray: [Data])? {
        func dataArrayFromString(_ string: String!, withSeparator separator: String) -> [Data] {
            var resultDataArray = [Data]()
            if let s = string {
                let stringArray = s.components(separatedBy: separator)
                for subString in stringArray {
                    if let data = subString.data(using: String.Encoding.utf8) {
                        resultDataArray.append(data)
                    }
                }
            }
            return resultDataArray
        }

        let splitArray = uriString.components(separatedBy: "?")

        if splitArray.count <= 2 {
            let resultPathDataArray = dataArrayFromString(splitArray.first, withSeparator: "/")
            let resultQueryDataArray = splitArray.count == 2 ? dataArrayFromString(splitArray.last, withSeparator: "&") : []

            return (resultPathDataArray, resultQueryDataArray)
        }
        return nil
    }

    public func inferredContentFormat() -> SCContentFormat {
        guard let contentFormatArray = options[SCOption.contentFormat.rawValue], let contentFormatData = contentFormatArray.first, let contentFormat = SCContentFormat(rawValue: UInt.fromData(contentFormatData)) else { return .plain }
        return contentFormat
    }

    public func payloadRepresentationString() -> String {
        guard let payloadData = payload else { return "" }

        return SCMessage.payloadRepresentationStringForData(payloadData, contentFormat: inferredContentFormat())
    }

    public static func payloadRepresentationStringForData(_ data: Data, contentFormat: SCContentFormat) -> String {
        if contentFormat.needsStringUTF8Conversion() {
            return (NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String?) ?? "Format Error"
        }
        return String.toHexFromData(data)
    }

    public func isObservation() -> Bool {
        return options.first { k, v in
            k == SCOption.observe.rawValue && v[0].allSatisfy { $0 == 0 }
        } != nil
    }

    public func toString() -> String {
        return "ID \(messageId ?? 0), token \(token), type: \(type.shortString()), code: \(code.toString()), path: \(completeUriPath()), observe: \(isObservation())"
    }
}
