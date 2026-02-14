/// snap/1 request containers for state snapshot synchronization.
const std = @import("std");
const primitives = @import("primitives");
const Hash = primitives.Hash;

/// GetAccountRange (0x00) request parameters.
///
/// Message shape from devp2p snap/1:
/// `[reqID, rootHash, startingHash, limitHash, responseBytes]`
pub const AccountRangeRequest = struct {
    pub const DEFAULT_RESPONSE_BYTES: u64 = 1_000_000;

    req_id: u64,
    root_hash: Hash.Hash,
    starting_hash: Hash.Hash,
    limit_hash: Hash.Hash,
    response_bytes: u64,

    /// Construct a GetAccountRange request.
    pub fn init(
        req_id: u64,
        root_hash: Hash.Hash,
        starting_hash: Hash.Hash,
        limit_hash: Hash.Hash,
        response_bytes: u64,
    ) AccountRangeRequest {
        return .{
            .req_id = req_id,
            .root_hash = root_hash,
            .starting_hash = starting_hash,
            .limit_hash = limit_hash,
            .response_bytes = if (response_bytes == 0) DEFAULT_RESPONSE_BYTES else response_bytes,
        };
    }
};

/// GetStorageRanges (0x02) request parameters.
///
/// Message shape from devp2p snap/1:
/// `[reqID, rootHash, accountHashes, startingHash, limitHash, responseBytes]`
pub const StorageRangeRequest = struct {
    req_id: u64,
    root_hash: Hash.Hash,
    account_hashes: []const Hash.Hash,
    starting_hash: Hash.Hash,
    limit_hash: Hash.Hash,
    response_bytes: u64,

    /// Construct a GetStorageRanges request.
    pub fn init(
        req_id: u64,
        root_hash: Hash.Hash,
        account_hashes: []const Hash.Hash,
        starting_hash: Hash.Hash,
        limit_hash: Hash.Hash,
        response_bytes: u64,
    ) StorageRangeRequest {
        return .{
            .req_id = req_id,
            .root_hash = root_hash,
            .account_hashes = account_hashes,
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
    const response_bytes: u64 = 512 * 1024;

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

test "AccountRangeRequest.init normalizes zero response bytes to default soft limit" {
    const request = AccountRangeRequest.init(
        7,
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
        [_]u8{0xcc} ** 32,
        0,
    );

    try std.testing.expectEqual(@as(u64, 7), request.req_id);
    try std.testing.expectEqual(AccountRangeRequest.DEFAULT_RESPONSE_BYTES, request.response_bytes);
}

test "StorageRangeRequest.init assigns all fields preserving account hash order" {
    const req_id: u64 = 314;
    const root_hash: Hash.Hash = [_]u8{0x10} ** 32;
    const account_hashes = [_]Hash.Hash{
        [_]u8{0x21} ** 32,
        [_]u8{0x32} ** 32,
        [_]u8{0x43} ** 32,
    };
    const starting_hash: Hash.Hash = [_]u8{0x54} ** 32;
    const limit_hash: Hash.Hash = [_]u8{0x65} ** 32;
    const response_bytes: u64 = 1024 * 1024;

    const request = StorageRangeRequest.init(
        req_id,
        root_hash,
        &account_hashes,
        starting_hash,
        limit_hash,
        response_bytes,
    );

    try std.testing.expectEqual(req_id, request.req_id);
    try std.testing.expectEqual(response_bytes, request.response_bytes);
    try std.testing.expectEqualSlices(u8, &root_hash, &request.root_hash);
    try std.testing.expectEqualSlices(u8, &starting_hash, &request.starting_hash);
    try std.testing.expectEqualSlices(u8, &limit_hash, &request.limit_hash);
    try std.testing.expectEqual(account_hashes.len, request.account_hashes.len);

    for (account_hashes, 0..) |expected, index| {
        try std.testing.expectEqualSlices(u8, &expected, &request.account_hashes[index]);
    }
}

test "StorageRangeRequest.init accepts empty account hash list" {
    const request = StorageRangeRequest.init(
        99,
        [_]u8{0xaa} ** 32,
        &[_]Hash.Hash{},
        [_]u8{0xbb} ** 32,
        [_]u8{0xcc} ** 32,
        4096,
    );

    try std.testing.expectEqual(@as(u64, 99), request.req_id);
    try std.testing.expectEqual(@as(usize, 0), request.account_hashes.len);
    try std.testing.expectEqual(@as(u64, 4096), request.response_bytes);
}
