import Foundation

@objc public protocol ParrotHostHelperProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func cancel(_ identifier: String)
}
