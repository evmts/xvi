/// World state management for the Guillotine execution client.
///
/// Provides journaled state with snapshot/restore for transaction processing,
/// sitting between the trie layer (Phase 1) and EVM state integration (Phase 3).
///
/// ## Architecture (Nethermind parity)
///
/// Follows Nethermind's separation of concerns:
///
/// | Module          | Nethermind equivalent            | Purpose                                    |
/// |-----------------|----------------------------------|--------------------------------------------|
/// | `journal`       | `PartialStorageProviderBase`     | Change-list journal with snapshot/restore   |
///
/// ## Modules
///
/// - `Snapshot`      — Composite snapshot positions (state + storage)
///
/// Account predicates (isEmpty, isAlive, hasCodeOrNonce, etc.) live on
/// `voltaire.AccountState.AccountState` directly.
const state = @import("state.zig");

// -- Public API: flat re-exports -------------------------------------------

// Snapshot types
/// Composite snapshot positions for state + persistent/transient storage.
pub const Snapshot = state.Snapshot;

test {
    // Ensure all sub-modules compile and their tests run.
    @import("std").testing.refAllDecls(@This());
}
