import ballerina/http;

// Exists solely to make this package declare a *direct* dependency on
// ballerina/http, so its version can be pinned in Ballerina.toml.
// ballerina/grpc (pulled in transitively via ballerina/a2a's gRPC binding)
// doesn't declare a Ballerina-level dependency on http at all -- its
// native Java code calls http's HttpLogManager directly -- so without
// this, Ballerina.toml's http version pin is silently ignored and the
// resolver picks whatever's newest on central, which is binary-
// incompatible with the grpc module's compiled Java code
// (IllegalAccessError at grpc module init). Same fix as tests/testutil.bal
// and demo/http_version_pin.bal -- see servers/dice_agent/findings.md #6.
#
# + return - an empty http:ClientConfiguration; never actually called
isolated function unusedHttpVersionPinAnchor() returns http:ClientConfiguration {
    return {};
}
