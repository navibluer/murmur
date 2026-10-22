import Foundation

public struct WebhookPayload: Decodable, Sendable {
    public let events: [WebhookEvent]
}

public struct WebhookEvent: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let type: String
        public let userId: String?
    }
    public struct DeliveryContext: Decodable, Sendable {
        public let isRedelivery: Bool
    }
    public struct ContentProvider: Decodable, Sendable {
        public let type: String
    }
    public struct Message: Decodable, Sendable {
        public let id: String
        public let type: String
        public let duration: Int?
        public let contentProvider: ContentProvider?
    }

    public let type: String
    public let webhookEventId: String
    public let replyToken: String?
    public let source: Source
    public let deliveryContext: DeliveryContext
    public let message: Message?
}
