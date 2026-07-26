import Foundation

struct CurrencyRateSnapshot: Sendable {
    let baseCurrency: String
    let rates: [String: Decimal]
}

struct CurrencyRateClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRates(from sourceCurrencies: Set<String>, to targetCurrency: String) async throws -> CurrencyRateSnapshot {
        let target = targetCurrency.uppercased()
        let sources = sourceCurrencies
            .map { $0.uppercased() }
            .filter { $0 != target }
            .sorted()

        guard !sources.isEmpty else {
            return CurrencyRateSnapshot(baseCurrency: target, rates: [target: 1])
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.frankfurter.dev"
        components.path = "/v2/rates"
        components.queryItems = [
            URLQueryItem(name: "base", value: target),
            URLQueryItem(name: "quotes", value: sources.joined(separator: ",")),
        ]
        guard let url = components.url else { throw CurrencyRateError.invalidRequest }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw CurrencyRateError.unavailable
        }

        let rows = try JSONDecoder().decode([CurrencyRateRow].self, from: data)
        var rates = [target: Decimal(1)]
        for row in rows where row.base == target && row.rate > 0 {
            rates[row.quote] = Decimal(1) / row.rate
        }

        guard sources.allSatisfy({ rates[$0] != nil }) else {
            throw CurrencyRateError.incompleteResponse
        }

        return CurrencyRateSnapshot(baseCurrency: target, rates: rates)
    }
}

private struct CurrencyRateRow: Decodable {
    let base: String
    let quote: String
    let rate: Decimal
}

private enum CurrencyRateError: LocalizedError {
    case invalidRequest
    case unavailable
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Could not prepare the exchange-rate request."
        case .unavailable:
            "Live exchange rates are unavailable right now."
        case .incompleteResponse:
            "Some exchange rates are unavailable right now."
        }
    }
}
