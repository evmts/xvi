/// Micro-benchmarks for RLPx framing helpers.
const std = @import("std");
const bench = @import("bench_utils");
const client_network = @import("client_network");

const max_packet_size: usize = 16 * 1024 * 1024;

noinline fn decode_frame_size_24_noinline(bytes: [3]u8) usize {
    return client_network.Frame.decode_frame_size_24(bytes);
}

noinline fn encode_frame_size_24_noinline(size: usize) ![3]u8 {
    return client_network.Frame.encode_frame_size_24(size);
}

fn bench_decode(iterations: usize) bench.BenchResult {
    var sum: usize = 0; // prevent optimization-out
    var state: u64 = 0x1234_5678_9ABC_DEF0;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        state +%= 0x9E37_79B9_7F4A_7C15;
        const bytes: [3]u8 = .{
            @intCast((state >> 16) & 0xFF),
            @intCast((state >> 8) & 0xFF),
            @intCast(state & 0xFF),
        };
        sum +%= decode_frame_size_24_noinline(bytes);
    }
    const end = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(sum);
    std.mem.doNotOptimizeAway(state);
    const elapsed: u64 = @intCast(end - start);
    return .{
        .name = "RLPx decode_frame_size_24([3]u8, varying)",
        .ops = iterations,
        .elapsed_ns = elapsed,
        .per_op_ns = if (iterations == 0) 0 else @as(u64, @intCast(elapsed / iterations)),
        .ops_per_sec = if (elapsed == 0) std.math.inf(f64) else @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0),
    };
}

fn bench_encode(iterations: usize) bench.BenchResult {
    var sink: u8 = 0; // prevent optimization-out
    var state: u64 = 0xA5A5_5A5A_D3C3_B4B4;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        state *%= 0x5851_F42D_4C95_7F2D;
        state +%= 0x1405_7B7E_F767_814F;
        const size: usize = @intCast(state & client_network.Frame.ProtocolMaxFrameSize);
        const out = encode_frame_size_24_noinline(size) catch unreachable;
        sink = sink ^ out[0] ^ out[1] ^ out[2];
    }
    const end = std.time.nanoTimestamp();
    const elapsed: u64 = @intCast(end - start);
    std.mem.doNotOptimizeAway(sink);
    std.mem.doNotOptimizeAway(state);
    return .{
        .name = "RLPx encode_frame_size_24(usize, varying)",
        .ops = iterations,
        .elapsed_ns = elapsed,
        .per_op_ns = if (iterations == 0) 0 else @as(u64, @intCast(elapsed / iterations)),
        .ops_per_sec = if (elapsed == 0) std.math.inf(f64) else @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0),
    };
}

fn bench_decode_header(
    iterations: usize,
    name: []const u8,
    frame_size: usize,
    header_data: []const u8,
) bench.BenchResult {
    var sink: usize = 0;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const out = client_network.Frame.decode_header_extensions(frame_size, header_data, max_packet_size) catch unreachable;
        sink +%= out.total_packet_size;
        sink +%= @intFromBool(out.is_chunked);
        sink +%= @intFromBool(out.is_first_chunk);
        sink +%= out.context_id orelse 0;
    }
    const end = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(sink);
    const elapsed: u64 = @intCast(end - start);
    return .{
        .name = name,
        .ops = iterations,
        .elapsed_ns = elapsed,
        .per_op_ns = if (iterations == 0) 0 else @as(u64, @intCast(elapsed / iterations)),
        .ops_per_sec = if (elapsed == 0) std.math.inf(f64) else @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0),
    };
}

fn bench_decode_header_non_chunked(iterations: usize) bench.BenchResult {
    const header_data = [_]u8{ 0xC2, 0x80, 0x80 } ++ [_]u8{0} ** 10;
    return bench_decode_header(
        iterations,
        "RLPx decode_header_extensions (non-chunked)",
        1024,
        &header_data,
    );
}

fn bench_decode_header_first_chunk(iterations: usize) bench.BenchResult {
    const header_data = [_]u8{ 0xC5, 0x80, 0x07, 0x82, 0x03, 0xE8 } ++ [_]u8{0} ** 7;
    return bench_decode_header(
        iterations,
        "RLPx decode_header_extensions (first-chunk)",
        256,
        &header_data,
    );
}

fn bench_decode_header_continuation_chunk(iterations: usize) bench.BenchResult {
    const header_data = [_]u8{ 0xC2, 0x80, 0x07 } ++ [_]u8{0} ** 10;
    return bench_decode_header(
        iterations,
        "RLPx decode_header_extensions (continuation)",
        512,
        &header_data,
    );
}

fn parse_iters_env(alloc: std.mem.Allocator, name: []const u8, default: usize) !usize {
    if (std.process.getEnvVarOwned(alloc, name)) |val| {
        defer alloc.free(val);
        return std.fmt.parseInt(usize, val, 10) catch |err| blk: {
            std.log.warn("ignoring invalid {s}='{s}': {s}", .{ name, val, @errorName(err) });
            break :blk default;
        };
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return default,
        else => return err,
    }
}

/// Runs RLPx frame helper micro-benchmarks.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Allow tuning via env vars. Header-extension decode is heavier than 24-bit size helpers.
    const frame_iters = try parse_iters_env(alloc, "RLPX_BENCH_ITERS", 10_000_000);
    const decode_header_iters = try parse_iters_env(alloc, "RLPX_DECODE_HEADER_BENCH_ITERS", 2_000_000);

    std.debug.print("RLPx Framing Benchmarks (frame-iters={d}, header-iters={d})\n", .{ frame_iters, decode_header_iters });
    bench.print_result(bench_decode(frame_iters));
    bench.print_result(bench_encode(frame_iters));
    bench.print_result(bench_decode_header_non_chunked(decode_header_iters));
    bench.print_result(bench_decode_header_first_chunk(decode_header_iters));
    bench.print_result(bench_decode_header_continuation_chunk(decode_header_iters));
    std.debug.print("  allocation-path: decode_header_extensions uses stack FixedBufferAllocator scratch (no heap)\n", .{});
}
