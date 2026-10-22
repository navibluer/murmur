import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore

private let signatureHeader = HTTPField.Name("x-line-signature")!
private let maxBodySize = 1_048_576

public func buildApplication(config: Config, pipeline: Pipeline) -> some ApplicationProtocol {
    let logger = Logger(label: "murmur")
    let router = Router()

    router.get("health") { _, _ -> String in "ok" }

    router.post("webhook") { request, _ -> HTTPResponse.Status in
        let received = ContinuousClock.now
        let buffer = try await request.body.collect(upTo: maxBodySize)
        let body = Data(buffer.readableBytesView)
        guard let signature = request.headers[signatureHeader],
            LineSignature.isValid(body: body, signature: signature, secret: config.lineChannelSecret)
        else {
            throw HTTPError(.unauthorized)
        }
        let payload: WebhookPayload
        do {
            payload = try JSONDecoder().decode(WebhookPayload.self, from: body)
        } catch {
            logger.error("webhook JSON 解碼失敗：\(error)")
            throw HTTPError(.badRequest)
        }
        Task {
            for event in payload.events {
                await pipeline.handle(event, receivedAt: received)
            }
        }
        return .ok
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: config.port), serverName: "murmur"),
        logger: logger)
}
