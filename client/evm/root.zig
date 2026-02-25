/// EVM integration layer for the Guillotine execution client.
///
/// Bridges Voltaire's `StateManager` to the guillotine-mini EVM engine via
/// a `HostInterface` adapter.
///
/// Transaction processing (intrinsic gas, validation, effective gas price)
/// is provided directly by `primitives.Transaction` (Voltaire upstream).
///
/// ## Architecture (Nethermind parity)
///
/// | Module          | Nethermind equivalent                      | Purpose                                |
/// |-----------------|--------------------------------------------|----------------------------------------|
/// | `HostAdapter`   | `IWorldState` passed to `VirtualMachine`   | State read/write bridge for EVM        |
///
/// ## Usage
///
/// ```zig
/// const host_adapter = @import("client_evm");
/// const primitives = @import("voltaire");
/// const Transaction = primitives.Transaction;
///
/// var state = try StateManager.init(allocator, null);
/// defer state.deinit();
///
/// var adapter = host_adapter.HostAdapter.init(&state);
/// const host = adapter.host_interface();
///
/// // Calculate intrinsic gas for a transaction
/// const tx = Transaction.LegacyTransaction{
///     .nonce = 0,
///     .gas_price = 0,
///     .gas_limit = 0,
///     .to = null,
///     .value = 0,
///     .data = tx_data,
///     .v = 0,
///     .r = [_]u8{0} ** 32,
///     .s = [_]u8{0} ** 32,
/// };
/// const gas = Transaction.calculateIntrinsicGas(tx, .CANCUN);
/// ```
const host_adapter = @import("host_adapter.zig");

/// Adapts Voltaire `StateManager` to guillotine-mini `HostInterface` vtable.
pub const HostAdapter = host_adapter.HostAdapter;

test {
    @import("std").testing.refAllDecls(@This());
}
