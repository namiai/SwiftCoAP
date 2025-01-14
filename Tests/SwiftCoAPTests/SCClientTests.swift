//
//  SCClientTests.swift
//
//
//  Created by Hoang Viet Tran on 04/04/2022.
//

@testable import SwiftCoAP
import XCTest

class SCClientTests: XCTestCase {
    private var client: SCClient!
    private var endpoint1 = NWEndpointMock().endpoint1
    private var messageSentExpectation: XCTestExpectation!
    private var sentMessage: SCMessage?

    internal var mockTransportLayer: MockSCCoAPTransportLayer!

    override func setUp() {
        mockTransportLayer = MockSCCoAPTransportLayer(client: self)
        client = SCClient(delegate: self, transportLayerObject: mockTransportLayer)
    }

    override func tearDown() {}

    func testInitDoesSetDelegateCorrectly() {
        let noDelegateClient = SCClient(delegate: nil, transportLayerObject: mockTransportLayer)

        XCTAssertNil(noDelegateClient.delegate)
    }

    func testSendCoAPMessageWithoutPayload() {
        let msg = SCMessage(code: SCCodeValue(classValue: 0, detailValue: 01)!, type: .confirmable, payload: nil)

        messageSentExpectation = expectation(description: "Did send message")

        client.sendCoAPMessage(msg, endpoint: endpoint1)

        waitForExpectations(timeout: 5)
        XCTAssertNotNil(sentMessage)
        XCTAssertEqual(msg, sentMessage)
    }

    func testCancelObserve() {
        let msg = SCMessage(code: SCCodeValue(classValue: 0, detailValue: 01)!, type: .confirmable, payload: nil)
        msg.endpoint = endpoint1
        client.messageInTransmission = msg

        client.cancelObserve()

        XCTAssertNotNil(mockTransportLayer.messageToSend)
        XCTAssertTrue(mockTransportLayer.messageToSend?.type == .nonConfirmable)
    }

    func testCloseTransmission() {
        let msg = SCMessage(code: SCCodeValue(classValue: 0, detailValue: 01)!, type: .confirmable, payload: nil)
        msg.endpoint = endpoint1
        client.messageInTransmission = msg
        client.closeTransmission()

        XCTAssertTrue(mockTransportLayer.canceledMessageTransmission)
        XCTAssertEqual(mockTransportLayer.canceledMessageTransmissionEndpoint, endpoint1)
    }

    func testSendWithRetransmissionHandling() {
        let msg = SCMessage(code: SCCodeValue(classValue: 0, detailValue: 01)!, type: .confirmable, payload: nil)
        msg.endpoint = endpoint1

        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 1)

        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 2)

        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 3)

        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 4)

        // by default max retransmission number is 4 cannot go over max
        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 4)
    }

    func testSendWithRetransmissionHandlingWithCancelTransmission() {
        let msg = SCMessage(code: SCCodeValue(classValue: 0, detailValue: 01)!, type: .confirmable, payload: nil)
        msg.endpoint = endpoint1

        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 1)
        client.closeTransmission()
        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 2)
        client.closeTransmission()
        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 3)
        client.closeTransmission()
        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 4)
        client.closeTransmission()
        // by default max retransmission number is 4 cannot go over max
        client.sendWithRentransmissionHandling()
        XCTAssertEqual(client.retransmissionCounter, 4)
    }
}

extension SCClientTests: SCClientDelegate {
    func swiftCoapClient(_: SCClient, didReceiveMessage _: SCMessage) {}

    func swiftCoapClient(_: SCClient, didFailWithError _: NSError) {}

    func swiftCoapClient(_: SCClient, didSendMessage message: SCMessage, number _: Int) {
        sentMessage = message
        messageSentExpectation.fulfill()
    }
}
