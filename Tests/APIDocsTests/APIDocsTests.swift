import XCTest
@testable import APIDocs

private let shopYAML = """
openapi: 3.0.3
info:
  title: Shop API
  version: 1.0
  description: Orders and users.
servers:
  - url: https://{env}.example.com/v1/
    variables:
      env:
        default: api
  - url: http://localhost:8080/v1
tags:
  - name: users
    description: People
x-shared:
  failure: &failure
    description: Something went wrong
    content:
      application/json:
        schema:
          $ref: '#/components/schemas/Error'
paths:
  /users:
    get:
      tags: [users]
      summary: List users
      parameters:
        - $ref: '#/components/parameters/Limit'
        - name: country
          in: query
          schema:
            type: string
            enum: [KR, NO, yes]
      responses:
        200:
          description: A page of users
          headers:
            X-Total:
              description: How many exist
              schema:
                type: integer
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/User'
              example: [{id: 1, name: Kim}]
        4XX: *failure
        default:
          $ref: '#/components/responses/Unexpected'
    post:
      operationId: createUser
      deprecated: true
      requestBody:
        $ref: '#/components/requestBodies/NewUser'
      responses:
        "201":
          description: Created
  /users/me:
    get:
      summary: The signed-in user
      responses:
        "200":
          description: OK
  /users/{id}:
    parameters:
      - name: id
        in: path
        schema:
          type: integer
      - name: X-Trace
        in: header
        description: From the path
    get:
      summary: One user
      parameters:
        - name: X-Trace
          in: header
          required: true
          description: From the operation
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
    delete:
      responses:
        "204":
          description: Gone
  /users/{id}/files/{name}.json:
    get:
      responses:
        "200":
          description: OK
  /files/{path}:
    get:
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema:
                $ref: 'other.yaml#/components/schemas/File'
  /broken:
    get:
      parameters:
        - $ref: '#/components/parameters/Missing'
      responses:
        "200":
          description: OK
components:
  parameters:
    Limit:
      name: limit
      in: query
      description: Page size
      schema:
        type: integer
        minimum: 1
        maximum: 100
        default: 20
  requestBodies:
    NewUser:
      required: true
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/User'
          examples:
            basic:
              summary: Smallest user
              value:
                name: Kim
  responses:
    Unexpected:
      description: Unexpected error
  schemas:
    Error:
      type: object
      properties:
        message:
          type: string
    User:
      type: object
      required: [id, name]
      properties:
        id:
          type: integer
          format: int64
          readOnly: true
        name:
          type: string
          minLength: 1
        nickname:
          type: string
          nullable: true
        manager:
          $ref: '#/components/schemas/User'
        role:
          allOf:
            - $ref: '#/components/schemas/Role'
        tags:
          type: object
          additionalProperties:
            type: string
    Role:
      type: string
      enum: [admin, member]
"""

final class ParserTests: XCTestCase {
    private func shop() throws -> APIDocument { try APIDocumentParser.parse(text: shopYAML) }

    private func operation(_ id: String, in document: APIDocument) throws -> APIOperation {
        try XCTUnwrap(document.operations.first { $0.id == id }, "no operation \(id)")
    }

    func testReadsInfoServersAndTags() throws {
        let document = try shop()
        XCTAssertEqual(document.title, "Shop API")
        XCTAssertEqual(document.version, "1.0")
        XCTAssertEqual(document.specVersion, "3.0.3")
        XCTAssertEqual(document.description, "Orders and users.")
        XCTAssertEqual(document.servers.map(\.url), ["https://api.example.com/v1/", "http://localhost:8080/v1"])
        XCTAssertEqual(document.servers.map(\.host), ["api.example.com", "localhost:8080"])
        XCTAssertEqual(document.servers.map(\.basePath), ["/v1", "/v1"])
        XCTAssertEqual(document.tags, [.init(name: "users", description: "People")])
    }

    func testListsOperationsInDocumentOrder() throws {
        XCTAssertEqual(try shop().operations.map(\.id), [
            "GET /users", "POST /users", "GET /users/me", "GET /users/{id}", "DELETE /users/{id}",
            "GET /users/{id}/files/{name}.json", "GET /files/{path}", "GET /broken",
        ])
    }

    func testReadsParametersIncludingReferencedOnes() throws {
        let list = try operation("GET /users", in: shop())
        XCTAssertEqual(list.summary, "List users")
        XCTAssertEqual(list.tags, ["users"])
        XCTAssertEqual(list.parameters.map(\.name), ["limit", "country"])
        let limit = list.parameters[0]
        XCTAssertEqual(limit.location, .query)
        XCTAssertFalse(limit.isRequired)
        XCTAssertEqual(limit.description, "Page size")
        XCTAssertEqual(limit.schema?.types, ["integer"])
        XCTAssertEqual(limit.schema?.minimum, 1)
        XCTAssertEqual(limit.schema?.maximum, 100)
        XCTAssertEqual(limit.schema?.defaultValue, .int(20))
        // Unquoted NO and yes are strings, not booleans.
        XCTAssertEqual(list.parameters[1].schema?.enumValues, [.string("KR"), .string("NO"), .string("yes")])
    }

    func testOperationParametersOverridePathLevelOnes() throws {
        let get = try operation("GET /users/{id}", in: shop())
        XCTAssertEqual(get.parameters.map(\.name), ["id", "X-Trace"])
        XCTAssertTrue(get.parameters[0].isRequired, "path parameters are always required")
        XCTAssertEqual(get.parameters[1].description, "From the operation")
        XCTAssertTrue(get.parameters[1].isRequired)

        let delete = try operation("DELETE /users/{id}", in: shop())
        XCTAssertEqual(delete.parameters.map(\.description), [nil, "From the path"])
    }

    func testReadsResponsesWithNumericKeysAliasesAndReferences() throws {
        let list = try operation("GET /users", in: shop())
        XCTAssertEqual(list.responses.map(\.status), ["200", "4XX", "default"])
        let ok = list.responses[0]
        XCTAssertEqual(ok.headers.map(\.name), ["X-Total"])
        XCTAssertEqual(ok.headers[0].schema?.types, ["integer"])
        XCTAssertEqual(ok.content.map(\.contentType), ["application/json"])
        XCTAssertEqual(ok.content[0].schema?.types, ["array"])
        XCTAssertEqual(ok.content[0].schema?.items?.reference, "#/components/schemas/User")
        XCTAssertEqual(ok.content[0].examples.first?.value.jsonText(), #"[{"id":1,"name":"Kim"}]"#)
        // A YAML alias (*failure) is read as the value it points at.
        XCTAssertEqual(list.responses[1].description, "Something went wrong")
        XCTAssertEqual(list.responses[1].content.first?.schema?.referenceName, "Error")
        XCTAssertEqual(list.responses[2].description, "Unexpected error")

        XCTAssertEqual(list.response(forStatus: 200)?.status, "200")
        XCTAssertEqual(list.response(forStatus: 404)?.status, "4XX")
        XCTAssertEqual(list.response(forStatus: 500)?.status, "default")
    }

    func testReadsReferencedRequestBody() throws {
        let create = try operation("POST /users", in: shop())
        XCTAssertEqual(create.operationID, "createUser")
        XCTAssertTrue(create.isDeprecated)
        let body = try XCTUnwrap(create.requestBody)
        XCTAssertTrue(body.isRequired)
        XCTAssertEqual(body.content.first?.schema?.reference, "#/components/schemas/User")
        XCTAssertEqual(body.content.first?.examples.first?.name, "basic")
        XCTAssertEqual(body.content.first?.examples.first?.summary, "Smallest user")
    }

    func testResolvesSchemasThatContainThemselves() throws {
        let document = try shop()
        let user = try XCTUnwrap(document.schemas["#/components/schemas/User"])
        XCTAssertEqual(user.name, "User")
        XCTAssertEqual(user.types, ["object"])
        XCTAssertEqual(user.properties.map(\.name), ["id", "name", "nickname", "manager", "role", "tags"])
        XCTAssertEqual(user.properties.map(\.isRequired), [true, true, false, false, false, false])
        XCTAssertEqual(user.properties[0].schema.format, "int64")
        XCTAssertTrue(user.properties[0].schema.isReadOnly)
        XCTAssertEqual(user.properties[1].schema.minLength, 1)
        XCTAssertTrue(user.properties[2].schema.isNullable)

        // User.manager is a User: the property stays a reference and resolves to the same schema.
        let manager = user.properties[3].schema
        XCTAssertEqual(manager.reference, "#/components/schemas/User")
        XCTAssertEqual(document.resolved(manager).properties.count, 6)

        // Schemas only reachable through other schemas are read too.
        let role = document.resolved(try XCTUnwrap(user.properties[4].schema.allOf.first))
        XCTAssertEqual(role.enumValues, [.string("admin"), .string("member")])
        XCTAssertEqual(user.properties[5].schema.additionalProperties?.types, ["string"])
        XCTAssertEqual(user.properties[5].schema.allowsAdditionalProperties, true)
    }

    func testUnresolvableReferencesBecomeWarnings() throws {
        let document = try shop()
        XCTAssertEqual(document.warnings.sorted(), [
            "Couldn't find #/components/parameters/Missing",
            "Skipped a reference to another file: other.yaml#/components/schemas/File",
        ])
        XCTAssertEqual(try operation("GET /broken", in: document).parameters.count, 0)
        // The schema keeps its reference, so the UI can still name it.
        let file = try XCTUnwrap(try operation("GET /files/{path}", in: document).responses.first?.content.first?.schema)
        XCTAssertEqual(document.resolved(file).referenceName, "File")
    }

    func testReadsJSONKeepingPropertyOrder() throws {
        let json = """
        {
          "openapi": "3.1.0",
          "info": {"title": "Pets", "version": "2.0.0"},
          "paths": {
            "/pets/{petId}": {
              "get": {
                "responses": {
                  "200": {
                    "description": "A pet \\ud83d\\udc36 \\u00e9\\n\\/",
                    "content": {"application/json": {"schema": {
                      "type": "object",
                      "properties": {
                        "zebra": {"type": ["string", "null"]},
                        "apple": {"type": "integer", "examples": [3, 4], "maximum": 1.5e2},
                        "mango": {"const": "fixed", "default": -0.5}
                      }
                    }}}
                  }
                }
              }
            }
          }
        }
        """
        let document = try APIDocumentParser.parse(Data([0xEF, 0xBB, 0xBF] + Array(json.utf8)))
        XCTAssertEqual(document.title, "Pets")
        XCTAssertEqual(document.specVersion, "3.1.0")
        XCTAssertTrue(document.servers.isEmpty)
        let response = try XCTUnwrap(document.operations.first?.responses.first)
        XCTAssertEqual(response.description, "A pet 🐶 é\n/")
        let schema = try XCTUnwrap(response.content.first?.schema)
        XCTAssertEqual(schema.properties.map(\.name), ["zebra", "apple", "mango"])
        // OpenAPI 3.1 spells nullable as a "null" type.
        XCTAssertEqual(schema.properties[0].schema.types, ["string"])
        XCTAssertTrue(schema.properties[0].schema.isNullable)
        XCTAssertEqual(schema.properties[1].schema.example, .int(3))
        XCTAssertEqual(schema.properties[1].schema.maximum, 150)
        XCTAssertEqual(schema.properties[2].schema.constValue, .string("fixed"))
        XCTAssertEqual(schema.properties[2].schema.defaultValue, .double(-0.5))
    }

    func testJSONReaderRejectsBrokenJSON() {
        for broken in ["{", "{\"a\": }", "[1, 2,]", "{\"a\": 1} x", "\"\\ud83d\"", "01", "{\"a\" 1}", "nul"] {
            var reader = JSONReader(broken)
            XCTAssertThrowsError(try reader.document(), broken)
        }
    }

    func testRejectsFilesThatAreNotOpenAPI3() {
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "swagger: \"2.0\"\ninfo: {}")) {
            XCTAssertEqual($0 as? APIDocError, .unsupportedVersion("Swagger 2.0"))
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "{\"swagger\": \"2.0\"}")) {
            XCTAssertEqual($0 as? APIDocError, .unsupportedVersion("Swagger 2.0"))
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "openapi: 4.0.0")) {
            XCTAssertEqual($0 as? APIDocError, .unsupportedVersion("OpenAPI 4.0.0"))
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "name: not an api")) {
            XCTAssertEqual($0 as? APIDocError, .notOpenAPI)
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "just some text")) {
            XCTAssertEqual($0 as? APIDocError, .notOpenAPI)
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "")) {
            XCTAssertEqual($0 as? APIDocError, .notOpenAPI)
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(text: "openapi: [3.0\npaths: {")) {
            guard case .syntax = $0 as? APIDocError else { return XCTFail("expected a syntax error, got \($0)") }
        }
        XCTAssertThrowsError(try APIDocumentParser.parse(Data([0xFF, 0xFE, 0x00, 0xD8]))) {
            XCTAssertEqual($0 as? APIDocError, .notText)
        }
    }

    func testPlainScalarsFollowTheYAMLCoreSchema() {
        XCTAssertEqual(DocValue(plainScalar: "12"), .int(12))
        XCTAssertEqual(DocValue(plainScalar: "-3"), .int(-3))
        XCTAssertEqual(DocValue(plainScalar: "0x1F"), .int(31))
        XCTAssertEqual(DocValue(plainScalar: "1.5"), .double(1.5))
        XCTAssertEqual(DocValue(plainScalar: "1e3"), .double(1000))
        XCTAssertEqual(DocValue(plainScalar: "true"), .bool(true))
        XCTAssertEqual(DocValue(plainScalar: "~"), .null)
        XCTAssertEqual(DocValue(plainScalar: "1.0.0"), .string("1.0.0"))
        XCTAssertEqual(DocValue(plainScalar: "off"), .string("off"))
        XCTAssertEqual(DocValue(plainScalar: "nan"), .string("nan"))
        XCTAssertEqual(DocValue(plainScalar: "2026-11-10"), .string("2026-11-10"))
    }

    func testWritesJSONText() {
        let value = DocValue.object(DocObject([
            .init(key: "b", value: .array([.int(1), .null, .bool(true)])),
            .init(key: "a", value: .string("line\n\"quoted\"")),
        ]))
        XCTAssertEqual(value.jsonText(), #"{"b":[1,null,true],"a":"line\n\"quoted\""}"#)
        XCTAssertEqual(DocValue.object(DocObject([.init(key: "k", value: .array([]))])).jsonText(pretty: true),
                       "{\n  \"k\": []\n}")
    }
}

final class MatcherTests: XCTestCase {
    private func matcher(hosts: [String]? = nil, basePaths: [String]? = nil) throws -> OperationMatcher {
        OperationMatcher(document: try APIDocumentParser.parse(text: shopYAML), hosts: hosts, basePaths: basePaths)
    }

    private func id(_ method: String, _ path: String, host: String = "api.example.com", port: Int? = nil,
                    in matcher: OperationMatcher) -> String? {
        matcher.match(method: method, host: host, port: port, path: path)?.operation.id
    }

    func testTakesHostsAndBasePathsFromServers() throws {
        let matcher = try matcher()
        XCTAssertEqual(matcher.hosts, ["api.example.com", "localhost:8080"])
        XCTAssertEqual(matcher.basePaths, ["/v1"])
    }

    func testMatchesMethodAndPathUnderTheBasePath() throws {
        let matcher = try matcher()
        XCTAssertEqual(id("GET", "/v1/users", in: matcher), "GET /users")
        XCTAssertEqual(id("post", "/v1/users", in: matcher), "POST /users")
        XCTAssertEqual(id("GET", "/v1/users/", in: matcher), "GET /users")
        XCTAssertEqual(id("GET", "/v1/users?limit=5&x=/a/b", in: matcher), "GET /users")
        XCTAssertNil(id("PATCH", "/v1/users", in: matcher), "method not documented")
        XCTAssertNil(id("GET", "/users", in: matcher), "outside the base path")
        XCTAssertNil(id("GET", "/v1x/users", in: matcher), "the base path must end at a slash")
        XCTAssertNil(id("GET", "/v1/users/1/extra", in: matcher))
        XCTAssertNil(id("GET", "/v1", in: matcher))
    }

    func testLiteralPathsBeatTemplatedOnes() throws {
        let matcher = try matcher()
        XCTAssertEqual(id("GET", "/v1/users/me", in: matcher), "GET /users/me")
        XCTAssertEqual(id("GET", "/v1/users/42", in: matcher), "GET /users/{id}")
        XCTAssertEqual(id("DELETE", "/v1/users/me", in: matcher), "DELETE /users/{id}",
                       "/users/me has no DELETE, so the template answers")
    }

    func testExtractsPathParameters() throws {
        let matcher = try matcher()
        let one = try XCTUnwrap(matcher.match(method: "GET", host: "api.example.com", path: "/v1/users/42"))
        XCTAssertEqual(one.pathParameters, ["id": "42"])

        let file = try XCTUnwrap(matcher.match(method: "GET", host: "api.example.com",
                                               path: "/v1/users/7/files/annual%20report.json"))
        XCTAssertEqual(file.operation.id, "GET /users/{id}/files/{name}.json")
        XCTAssertEqual(file.pathParameters, ["id": "7", "name": "annual report"])
        XCTAssertNil(id("GET", "/v1/users/7/files/report.txt", in: matcher))
        XCTAssertNil(id("GET", "/v1/users/7/files/.json", in: matcher), "a parameter can't be empty")

        let encoded = try XCTUnwrap(matcher.match(method: "GET", host: "api.example.com", path: "/v1/files/a%2Fb"))
        XCTAssertEqual(encoded.pathParameters, ["path": "a/b"])
    }

    func testAppliesOnlyToItsHosts() throws {
        let matcher = try matcher()
        XCTAssertEqual(id("GET", "/v1/users", host: "API.Example.com", in: matcher), "GET /users")
        XCTAssertEqual(id("GET", "/v1/users", host: "api.example.com", port: 8443, in: matcher), "GET /users",
                       "a host without a port matches any port")
        XCTAssertEqual(id("GET", "/v1/users", host: "localhost", port: 8080, in: matcher), "GET /users")
        XCTAssertNil(id("GET", "/v1/users", host: "localhost", port: 3000, in: matcher))
        XCTAssertNil(id("GET", "/v1/users", host: "other.example.com", in: matcher))
    }

    func testHostsAndBasePathsCanBeOverridden() throws {
        let staging = try matcher(hosts: [" Staging.internal ", "*.dev.example.com"], basePaths: ["api/v2/", ""])
        XCTAssertEqual(staging.hosts, ["staging.internal", "*.dev.example.com"])
        XCTAssertEqual(staging.basePaths, ["/api/v2", ""])
        XCTAssertEqual(id("GET", "/api/v2/users/me", host: "staging.internal", in: staging), "GET /users/me")
        XCTAssertEqual(id("GET", "/users/me", host: "kim.dev.example.com", in: staging), "GET /users/me")
        XCTAssertNil(id("GET", "/users/me", host: "dev.example.com", in: staging))
        XCTAssertNil(id("GET", "/users/me", host: "api.example.com", in: staging))

        let anyHost = try matcher(hosts: [])
        XCTAssertEqual(id("GET", "/v1/users", host: "whatever.test", in: anyHost), "GET /users")
    }

    func testDocumentWithoutServersMatchesAnyHostAtTheRoot() throws {
        let document = try APIDocumentParser.parse(text: """
        openapi: 3.1.0
        info: {title: Bare, version: "1"}
        paths:
          /:
            get:
              responses: {}
          /{a}/{b}:
            get:
              responses: {}
          /{a}/list:
            get:
              responses: {}
        """)
        let matcher = OperationMatcher(document: document)
        XCTAssertEqual(matcher.hosts, [])
        XCTAssertEqual(matcher.basePaths, [""])
        XCTAssertEqual(matcher.match(method: "GET", host: "x.test", path: "/")?.operation.id, "GET /")
        XCTAssertEqual(matcher.match(method: "GET", host: "x.test", path: "")?.operation.id, "GET /")
        XCTAssertEqual(matcher.match(method: "GET", host: "x.test", path: "/shop/list")?.operation.id, "GET /{a}/list")
        XCTAssertEqual(matcher.match(method: "GET", host: "x.test", path: "/shop/other")?.operation.id, "GET /{a}/{b}")
    }
}
