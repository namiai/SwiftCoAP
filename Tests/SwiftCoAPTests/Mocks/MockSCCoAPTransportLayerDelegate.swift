//
//  File.swift
//
//
//  Created by Hoang Viet Tran on 06/04/2022.
//

import Foundation
import Network
import SwiftCoAP

class MockSCCoAPTransportLayerDelegate: SCCoAPTransportLayerDelegate {
    var host: String?
    var port: UInt16?
    var endpoint: NWEndpoint?
    var dataFromHost: Data?
    var dataFromEndpoint: Data?
    var error: NSError?

    func transportLayerObject(_: SCCoAPTransportLayerProtocol, didReceiveData data: Data, fromHost host: String, port: UInt16) {
        dataFromHost = data
        self.host = host
        self.port = port
    }

    func transportLayerObject(_: SCCoAPTransportLayerProtocol, didReceiveData data: Data, fromEndpoint endpoint: NWEndpoint) {
        dataFromEndpoint = data
        self.endpoint = endpoint
    }

    // Error occured. Provide an appropriate NSError object.
    func transportLayerObject(_: SCCoAPTransportLayerProtocol, didFailWithError error: NSError) {
        self.error = error
    }
}
