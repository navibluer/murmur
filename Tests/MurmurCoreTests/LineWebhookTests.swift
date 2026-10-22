import Foundation
import Testing
@testable import MurmurCore

@Suite struct LineWebhookTests {
    func decode(_ s: String) throws -> WebhookPayload {
        try JSONDecoder().decode(WebhookPayload.self, from: Data(s.utf8))
    }

    @Test func audio() throws {
        let p = try decode(#"{"destination":"U0","events":[{"type":"message","message":{"type":"audio","id":"325708","duration":60000,"contentProvider":{"type":"line"}},"webhookEventId":"01FZ74A0TDDPYRVKNK77XKC3ZR","deliveryContext":{"isRedelivery":false},"timestamp":1692251666727,"source":{"type":"user","userId":"U4af4980629"},"replyToken":"38ef843bde154d9b91c21320ffd17a0f","mode":"active"}]}"#)
        let e = p.events[0]
        #expect(e.message?.type == "audio")
        #expect(e.message?.duration == 60000)
        #expect(e.message?.contentProvider?.type == "line")
        #expect(e.message?.id == "325708")
        #expect(e.source.userId == "U4af4980629")
        #expect(e.deliveryContext.isRedelivery == false)
        #expect(e.replyToken == "38ef843bde154d9b91c21320ffd17a0f")
    }

    @Test func textAndFollow() throws {
        let p = try decode(#"{"events":[{"type":"message","message":{"type":"text","id":"1","text":"hi"},"webhookEventId":"a","deliveryContext":{"isRedelivery":true},"source":{"type":"user","userId":"U1"},"replyToken":"r"},{"type":"follow","webhookEventId":"b","deliveryContext":{"isRedelivery":false},"source":{"type":"user","userId":"U1"},"replyToken":"r2"}]}"#)
        #expect(p.events.count == 2)
        #expect(p.events[0].message?.type == "text")
        #expect(p.events[0].message?.duration == nil)
        #expect(p.events[1].message == nil)
    }
}
