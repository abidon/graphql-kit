import XCTest
import Vapor
import XCTVapor
@testable import GraphQLKit

final class GraphQLKitTests: XCTestCase {
    struct SomeBearerAuthenticator: BearerAuthenticator {
        struct User: Authenticatable {}
        
        func authenticate(bearer: BearerAuthorization, for request: Request) -> EventLoopFuture<()> {
            // Bearer token should be equal to `token` to pass the auth
            if bearer.token == "token" {
                request.auth.login(User())
                return request.eventLoop.makeSucceededFuture(())
            } else {
                return request.eventLoop.makeFailedFuture(Abort(.unauthorized))
            }
        }
        
        func authenticate(request: Request) -> EventLoopFuture<()> {
            // Bearer token should be equal to `token` to pass the auth
            if request.headers.bearerAuthorization?.token == "token" {
                request.auth.login(User())
                return request.eventLoop.makeSucceededFuture(())
            } else {
                return request.eventLoop.makeFailedFuture(Abort(.unauthorized))
            }
        }
    }
    
    struct ProtectedResolver {
        func test(store: Request, _: NoArguments) throws -> String {
            _ = try store.auth.require(SomeBearerAuthenticator.User.self)
            return "Hello World"
        }

        func number(store: Request, _: NoArguments) throws -> Int {
            _ = try store.auth.require(SomeBearerAuthenticator.User.self)
            return 42
        }
    }
    
    struct Resolver {
        func test(store: Request, _: NoArguments) -> String {
            "Hello World"
        }

        func number(store: Request, _: NoArguments) -> Int {
            42
        }
    }
    
    let protectedSchema = try! Schema<ProtectedResolver, Request> {
        Query {
            Field("test", at: ProtectedResolver.test)
            Field("number", at: ProtectedResolver.number)
        }
    }

    let schema = try! Schema<Resolver, Request> {
        Query {
            Field("test", at: Resolver.test)
            Field("number", at: Resolver.number)
        }
    }
    
    let query = """
    query {
        test
    }
    """

    func testPostEndpoint() throws {
        let queryRequest = QueryRequest(query: query, operationName: nil, variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!

        let app = Application(.testing)
        defer { app.shutdown() }

        app.register(graphQLSchema: schema, withResolver: Resolver())

        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeString(data)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
        headers.contentType = .json

        try app.testable().test(.POST, "/graphql", headers: headers, body: body) { res in
            XCTAssertEqual(res.status, .ok)
            var res = res
            let expected = #"{"data":{"test":"Hello World"}}"#
            XCTAssertEqual(res.body.readString(length: expected.count), expected)
        }
    }

    func testGetEndpoint() throws {
        let app = Application(.testing)
        defer { app.shutdown() }

        app.register(graphQLSchema: schema, withResolver: Resolver())
        try app.testable().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)") { res in
            XCTAssertEqual(res.status, .ok)
            var body = res.body
            let expected = #"{"data":{"test":"Hello World"}}"#
            XCTAssertEqual(body.readString(length: expected.count), expected)
        }
    }
    
    func testPostOperatinName() throws {
        let multiQuery = """
            query World {
                test
            }

            query Number {
                number
            }
            """
        let queryRequest = QueryRequest(query: multiQuery, operationName: "Number", variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!

        let app = Application(.testing)
        defer { app.shutdown() }

        app.register(graphQLSchema: schema, withResolver: Resolver())

        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeString(data)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
        headers.contentType = .json

        try app.testable().test(.POST, "/graphql", headers: headers, body: body) { res in
            XCTAssertEqual(res.status, .ok)
            var res = res
            let expected = #"{"data":{"number":42}}"#
            XCTAssertEqual(res.body.readString(length: expected.count), expected)
        }
    }
    
    func testProtectedPostEndpoint() throws {
        let queryRequest = QueryRequest(query: query, operationName: nil, variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!

        let app = Application(.testing)
        defer { app.shutdown() }

        let protected = app.grouped(SomeBearerAuthenticator())
        protected.register(graphQLSchema: protectedSchema, withResolver: ProtectedResolver())

        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeString(data)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
        headers.contentType = .json
        
        var protectedHeaders = headers
        protectedHeaders.replaceOrAdd(name: .authorization, value: "Bearer token")
        
        try app.testable().test(.POST, "/graphql", headers: headers, body: body) { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
        
        try app.testable().test(.POST, "/graphql", headers: protectedHeaders, body: body) { res in
            XCTAssertEqual(res.status, .ok)
            var res = res
            let expected = #"{"data":{"test":"Hello World"}}"#
            XCTAssertEqual(res.body.readString(length: expected.count), expected)
        }
    }
    
    func testProtectedGetEndpoint() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        
        let protected = app.grouped(SomeBearerAuthenticator())
        protected.register(graphQLSchema: protectedSchema, withResolver: ProtectedResolver())
        
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .authorization, value: "Bearer token")
        
        try app.testable().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
        
        try app.testable().test(.GET, "/graphql?query=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)", headers: headers) { res in
            XCTAssertEqual(res.status, .ok)
            var body = res.body
            let expected = #"{"data":{"test":"Hello World"}}"#
            XCTAssertEqual(body.readString(length: expected.count), expected)
        }
    }
    
    func testProtectedPostOperatinName() throws {
        let multiQuery = """
            query World {
                test
            }

            query Number {
                number
            }
            """
        let queryRequest = QueryRequest(query: multiQuery, operationName: "Number", variables: nil)
        let data = String(data: try! JSONEncoder().encode(queryRequest), encoding: .utf8)!

        let app = Application(.testing)
        defer { app.shutdown() }

        let protected = app.grouped(SomeBearerAuthenticator())
        protected.register(graphQLSchema: protectedSchema, withResolver: ProtectedResolver())

        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeString(data)
        
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentLength, value: body.readableBytes.description)
        headers.contentType = .json
        
        var protectedHeaders = headers
        protectedHeaders.replaceOrAdd(name: .authorization, value: "Bearer token")
        
        try app.testable().test(.POST, "/graphql", headers: headers, body: body) { res in
            XCTAssertEqual(res.status, .unauthorized)
        }

        try app.testable().test(.POST, "/graphql", headers: protectedHeaders, body: body) { res in
            XCTAssertEqual(res.status, .ok)
            var res = res
            let expected = #"{"data":{"number":42}}"#
            XCTAssertEqual(res.body.readString(length: expected.count), expected)
        }
    }
}
