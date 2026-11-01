import Foundation

extension Data {
    /// Append a multipart form field with a string value.
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    /// Append a multipart form field with file data.
    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}

/// A plain-text multipart field. Request builders return these so tests can
/// check exactly what a provider would send without parsing a body.
struct MultipartFormField: Equatable {
    let name: String
    let value: String
}

extension Data {
    mutating func appendMultipart(boundary: String, fields: [MultipartFormField]) {
        for field in fields {
            appendMultipart(boundary: boundary, name: field.name, value: field.value)
        }
    }
}
