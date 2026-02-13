/// snap/1 request containers for state snapshot synchronization.
const std = @import("std");
const primitives = @import("primitives");
const Hash = primitives.Hash;

/// GetAccountRange (0x00) request parameters.
///
/// Message shape from devp2p snap/1:
/// `[reqID, rootHash, startingHash, limitHash, responseBytes]`
pub const AccountRangeRequest = struct {
    req_id: u64,
    root_hash: Hash.Hash,
    starting_hash: Hash.Hash,
    limit_hash: Hash.Hash,
    response_bytes: usize,

    /// Construct a GetAccountRange request.
    pub fn init(
        req_id: u64,
        root_hash: Hash.Hash,
        starting_hash: Hash.Hash,
        limit_hash: Hash.Hash,
        response_bytes: usize,
    ) AccountRangeRequest {
        return .{
            .req_id = req_id,
            .root_hash = root_hash,
            .starting_hash = starting_hash,
            .limit_hash = limit_hash,
            .response_bytes = response_bytes,
        };
    }
};

test "AccountRangeRequest.init assigns all fields" {
    const req_id: u64 = 42;
    const root_hash: Hash.Hash = [_]u8{0x11} ** 32;
    const starting_hash: Hash.Hash = [_]u8{0x22} ** 32;
    const limit_hash: Hash.Hash = [_]u8{0x33} ** 32;
    const response_bytes: usize = 512 * 1024;

    const request = AccountRangeRequest.init(
        req_id,
        root_hash,
        starting_hash,
        limit_hash,
        response_bytes,
    );

    try std.testing.expectEqual(req_id, request.req_id);
    try std.testing.expectEqual(response_bytes, request.response_bytes);
    try std.testing.expectEqualSlices(u8, &root_hash, &request.root_hash);
    try std.testing.expectEqualSlices(u8, &starting_hash, &request.starting_hash);
    try std.testing.expectEqualSlices(u8, &limit_hash, &request.limit_hash);
}

test "AccountRangeRequest.init accepts zero response bytes" {
    const request = AccountRangeRequest.init(
        7,
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
        [_]u8{0xcc} ** 32,
        0,
    );

    try std.testing.expectEqual(@as(u64, 7), request.req_id);
    try std.testing.expectEqual(@as(usize, 0), request.response_bytes);
}
