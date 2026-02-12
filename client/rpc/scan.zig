//! Lightweight JSON scanner utilities for top-level key detection.
//!
//! Shared by envelope and dispatch to avoid code duplication. These
//! functions are allocation-free and operate on raw bytes.
const std = @import("std");

pub const ScanRequestError = error{
    ParseError,
    InvalidRequest,
};

pub const ValueSpan = struct {
    start: usize,
    end: usize,
};

pub const RequestFieldSpans = struct {
    jsonrpc: ?ValueSpan = null,
    method: ?ValueSpan = null,
};

/// Return the index at which the given JSON object key (including quotes)
/// appears as a direct child of the top-level object. Returns null if the
/// key is not found at the top level. The index points to the opening '"'.
pub inline fn find_top_level_key(input: []const u8, key: []const u8) ?usize {
    var depth: u32 = 0;
    var in_string = false;
    var escaped = false;
    var expecting_key = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => {
                if (depth == 1 and expecting_key) {
                    const rem = input[i..];
                    if (rem.len >= key.len and std.mem.eql(u8, rem[0..key.len], key)) {
                        return i;
                    }
                }
                in_string = true;
            },
            '{' => {
                depth += 1;
                if (depth == 1) expecting_key = true;
            },
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 1) expecting_key = false;
            },
            '[' => depth += 1,
            ']' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            ':' => {
                if (depth == 1) expecting_key = false;
            },
            ',' => {
                if (depth == 1) expecting_key = true;
            },
            else => {},
        }
    }
    return null;
}

fn skip_whitespace(input: []const u8, index: *usize) void {
    while (index.* < input.len and std.ascii.isWhitespace(input[index.*])) : (index.* += 1) {}
}

fn parse_json_string(input: []const u8, index: *usize) ScanRequestError!void {
    if (index.* >= input.len or input[index.*] != '"') return error.ParseError;
    index.* += 1;
    while (index.* < input.len) : (index.* += 1) {
        const ch = input[index.*];
        if (ch == '"') {
            index.* += 1;
            return;
        }
        if (ch == '\\') {
            index.* += 1;
            if (index.* >= input.len) return error.ParseError;
            const esc = input[index.*];
            switch (esc) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
                'u' => {
                    var n: usize = 0;
                    while (n < 4) : (n += 1) {
                        index.* += 1;
                        if (index.* >= input.len) return error.ParseError;
                        if (!std.ascii.isHex(input[index.*])) return error.ParseError;
                    }
                },
                else => return error.ParseError,
            }
            continue;
        }
        if (ch < 0x20) return error.ParseError;
    }
    return error.ParseError;
}

fn parse_json_number(input: []const u8, index: *usize) ScanRequestError!void {
    if (index.* < input.len and input[index.*] == '-') index.* += 1;
    if (index.* >= input.len) return error.ParseError;

    if (input[index.*] == '0') {
        index.* += 1;
    } else if (std.ascii.isDigit(input[index.*])) {
        while (index.* < input.len and std.ascii.isDigit(input[index.*])) : (index.* += 1) {}
    } else {
        return error.ParseError;
    }

    if (index.* < input.len and input[index.*] == '.') {
        index.* += 1;
        if (index.* >= input.len or !std.ascii.isDigit(input[index.*])) return error.ParseError;
        while (index.* < input.len and std.ascii.isDigit(input[index.*])) : (index.* += 1) {}
    }

    if (index.* < input.len and (input[index.*] == 'e' or input[index.*] == 'E')) {
        index.* += 1;
        if (index.* < input.len and (input[index.*] == '+' or input[index.*] == '-')) index.* += 1;
        if (index.* >= input.len or !std.ascii.isDigit(input[index.*])) return error.ParseError;
        while (index.* < input.len and std.ascii.isDigit(input[index.*])) : (index.* += 1) {}
    }
}

fn parse_json_literal(input: []const u8, index: *usize, comptime lit: []const u8) ScanRequestError!void {
    if (input.len - index.* < lit.len) return error.ParseError;
    if (!std.mem.eql(u8, input[index.* .. index.* + lit.len], lit)) return error.ParseError;
    index.* += lit.len;
}

fn parse_json_object_value(input: []const u8, index: *usize) ScanRequestError!void {
    if (index.* >= input.len or input[index.*] != '{') return error.ParseError;
    index.* += 1;
    skip_whitespace(input, index);
    if (index.* >= input.len) return error.ParseError;
    if (input[index.*] == '}') {
        index.* += 1;
        return;
    }

    while (true) {
        try parse_json_string(input, index);
        skip_whitespace(input, index);
        if (index.* >= input.len or input[index.*] != ':') return error.ParseError;
        index.* += 1;
        skip_whitespace(input, index);
        try parse_json_value(input, index);
        skip_whitespace(input, index);
        if (index.* >= input.len) return error.ParseError;
        if (input[index.*] == '}') {
            index.* += 1;
            return;
        }
        if (input[index.*] != ',') return error.ParseError;
        index.* += 1;
        skip_whitespace(input, index);
    }
}

fn parse_json_array(input: []const u8, index: *usize) ScanRequestError!void {
    if (index.* >= input.len or input[index.*] != '[') return error.ParseError;
    index.* += 1;
    skip_whitespace(input, index);
    if (index.* >= input.len) return error.ParseError;
    if (input[index.*] == ']') {
        index.* += 1;
        return;
    }

    while (true) {
        try parse_json_value(input, index);
        skip_whitespace(input, index);
        if (index.* >= input.len) return error.ParseError;
        if (input[index.*] == ']') {
            index.* += 1;
            return;
        }
        if (input[index.*] != ',') return error.ParseError;
        index.* += 1;
        skip_whitespace(input, index);
    }
}

fn parse_json_value(input: []const u8, index: *usize) ScanRequestError!void {
    if (index.* >= input.len) return error.ParseError;
    switch (input[index.*]) {
        '"' => try parse_json_string(input, index),
        '{' => try parse_json_object_value(input, index),
        '[' => try parse_json_array(input, index),
        't' => try parse_json_literal(input, index, "true"),
        'f' => try parse_json_literal(input, index, "false"),
        'n' => try parse_json_literal(input, index, "null"),
        '-', '0'...'9' => try parse_json_number(input, index),
        else => return error.ParseError,
    }
}

/// Parse a request object once and capture top-level `jsonrpc` and `method`
/// value spans while validating full JSON structure.
pub fn scan_request_fields(input: []const u8) ScanRequestError!RequestFieldSpans {
    var i: usize = 0;
    if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) i = 3;
    skip_whitespace(input, &i);
    if (i >= input.len) return error.ParseError;
    if (input[i] == '[') return error.InvalidRequest;
    if (input[i] != '{') return error.InvalidRequest;

    var fields = RequestFieldSpans{};
    i += 1;
    skip_whitespace(input, &i);
    if (i >= input.len) return error.ParseError;
    if (input[i] == '}') return error.ParseError;

    while (true) {
        if (i >= input.len or input[i] != '"') return error.ParseError;
        const key_start = i;
        try parse_json_string(input, &i);
        const key_end = i;
        const key_token = input[key_start..key_end];

        skip_whitespace(input, &i);
        if (i >= input.len or input[i] != ':') return error.ParseError;
        i += 1;
        skip_whitespace(input, &i);

        const value_start = i;
        try parse_json_value(input, &i);
        const value_end = i;

        if (fields.jsonrpc == null and std.mem.eql(u8, key_token, "\"jsonrpc\"")) {
            fields.jsonrpc = .{ .start = value_start, .end = value_end };
        } else if (fields.method == null and std.mem.eql(u8, key_token, "\"method\"")) {
            fields.method = .{ .start = value_start, .end = value_end };
        }

        skip_whitespace(input, &i);
        if (i >= input.len) return error.ParseError;
        if (input[i] == '}') {
            i += 1;
            break;
        }
        if (input[i] != ',') return error.ParseError;
        i += 1;
        skip_whitespace(input, &i);
    }

    skip_whitespace(input, &i);
    if (i != input.len) return error.ParseError;
    return fields;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "find_top_level_key finds method at top-level only" {
    const json =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"params\": { \"method\": \"nested\" },\n" ++
        "  \"method\": \"eth_blockNumber\"\n" ++
        "}";
    try std.testing.expect(find_top_level_key(json, "\"method\"") != null);
}

test "find_top_level_key ignores nested keys" {
    const json =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"obj\": { \"id\": 1 }\n" ++
        "}";
    try std.testing.expect(find_top_level_key(json, "\"id\"") == null);
}

test "scanRequestFields captures jsonrpc and method spans" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"id\": 1,\n" ++
        "  \"method\": \"eth_blockNumber\",\n" ++
        "  \"params\": []\n" ++
        "}";
    const out = try scan_request_fields(req);
    try std.testing.expect(out.jsonrpc != null);
    try std.testing.expect(out.method != null);
    try std.testing.expectEqualStrings("\"2.0\"", req[out.jsonrpc.?.start..out.jsonrpc.?.end]);
    try std.testing.expectEqualStrings("\"eth_blockNumber\"", req[out.method.?.start..out.method.?.end]);
}

test "scanRequestFields rejects malformed object" {
    const req =
        "{\n" ++
        "  \"jsonrpc\": \"2.0\",\n" ++
        "  \"method\": \"eth_blockNumber\",\n" ++
        "}";
    try std.testing.expectError(error.ParseError, scan_request_fields(req));
}

test "scanRequestFields rejects invalid JSON with trailing tokens" {
    const req = "{ \"jsonrpc\": \"2.0\", \"method\": \"eth_blockNumber\" } garbage";
    try std.testing.expectError(error.ParseError, scan_request_fields(req));
}
