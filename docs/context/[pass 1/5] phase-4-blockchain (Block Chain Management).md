# Context - [pass 1/5] phase-4-blockchain (Block Chain Management)

Focused implementation context for chain structure and block validation, using Voltaire primitives and the existing guillotine-mini EVM.

## Phase Goals (`prd/GUILLOTINE_CLIENT_PLAN.md`)

- Phase: `phase-4-blockchain`
- Goal: Manage blockchain structure and validation.
- Planned units:
  - `client/blockchain/chain.zig`
  - `client/blockchain/validator.zig`
- Structural references:
  - `nethermind/src/Nethermind/Nethermind.Blockchain/`
  - `voltaire/packages/voltaire-zig/src/blockchain/`
- Primary fixture suite:
  - `ethereum-tests/BlockchainTests/`

## Relevant Specs (`prd/ETHEREUM_SPECS_REFERENCE.md` + direct files)

### execution-specs

- `execution-specs/src/ethereum/forks/paris/fork.py`
  - Core post-Merge `state_transition`, `validate_header`, base fee checks, PoS header constraints.
- `execution-specs/src/ethereum/forks/shanghai/fork.py`
  - Adds withdrawal processing and `withdrawals_root` validation.
- `execution-specs/src/ethereum/forks/cancun/fork.py`
  - Adds blob-related header/body validation (`blob_gas_used`, `excess_blob_gas`) and beacon root flow.
- `execution-specs/src/ethereum/forks/*/fork.py`
  - Canonical reference for per-fork block/header validation logic.

### EIPs (blockchain-management relevant)

- `EIPs/EIPS/eip-1559.md` - base fee and gas-limit adjustment rules.
- `EIPs/EIPS/eip-3675.md` - Merge transition and PoS execution-layer constraints.
- `EIPs/EIPS/eip-4399.md` - `PREVRANDAO` semantics.
- `EIPs/EIPS/eip-4895.md` - withdrawals payload and root commitments.
- `EIPs/EIPS/eip-4788.md` - `parent_beacon_block_root` and EL system call behavior.
- `EIPs/EIPS/eip-4844.md` - blob tx/header fields and blob gas accounting.
- `EIPs/EIPS/eip-7685.md` - requests commitment (`requests_hash`).

### Yellow Paper / devp2p references

- `yellowpaper/Paper.tex`
  - `\section{Block Finalisation}` and `\subsubsection{Block Header Validity}` for formal validity relations.
- `devp2p/caps/eth.md`
  - ETH wire messages for chain sync and block import flow: `Status`, `GetBlockHeaders`, `BlockHeaders`, `GetBlockBodies`, `BlockBodies`, `GetReceipts`, `Receipts`, `NewBlock`, `NewBlockHashes`.

## Nethermind DB Inventory (`nethermind/src/Nethermind/Nethermind.Db/`)

Key storage/provider files to mirror architecturally (not line-by-line):

- `DbProvider.cs`, `DbProviderExtensions.cs`, `DbNames.cs`
- `IDb.cs`, `IReadOnlyDb.cs`, `IColumnsDb.cs`, `IDbFactory.cs`, `IDbProvider.cs`
- `ReadOnlyDb.cs`, `ReadOnlyColumnsDb.cs`, `ReadOnlyDbProvider.cs`
- `MemDb.cs`, `MemColumnsDb.cs`, `MemDbFactory.cs`
- `CompressingDb.cs`, `RocksDbSettings.cs`
- `MetadataDbKeys.cs`, `ReceiptsColumns.cs`, `BlobTxsColumns.cs`
- `IPruningConfig.cs`, `PruningConfig.cs`, `PruningMode.cs`
- `FullPruning/FullPruningDb.cs`, `FullPruning/FullPruningInnerDbFactory.cs`
- `Metrics.cs`

## Voltaire APIs (`/Users/williamcory/voltaire/packages/voltaire-zig/src/`)

Relevant top-level modules:

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/state-manager/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/evm/`

Blockchain APIs to reuse directly:

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/root.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig`
  - `BlockStore.init`, `putBlock`, `getBlock`, `getBlockByNumber`, `getCanonicalHash`, `setCanonicalHead`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig`
  - `Blockchain.init`, `getBlockByHash`, `getBlockByNumber`, `putBlock`, `setCanonicalHead`, `isForkBlock`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/blockchain/ForkBlockCache.zig`
  - `ForkBlockCache.init`, `getBlockByNumber`, `getBlockByHash`, `nextRequest`, `continueRequest`

Primitive families to prefer over custom types:

- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Block/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockHeader/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/BlockBody/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/Hash/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/ChainHead/`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/primitives/ForkId/`

## Existing Host Interface

Requested path:

- `src/host.zig` (not present in this repository)

Actual file:

- `guillotine-mini/src/host.zig`

HostInterface summary:

- VTable-based host boundary for external state reads/writes only.
- Exposed methods: `getBalance`, `setBalance`, `getCode`, `setCode`, `getStorage`, `setStorage`, `getNonce`, `setNonce`.
- Nested call flow is handled internally in the guillotine-mini EVM, not via this interface.

## Test Fixtures

Ethereum tests:

- `ethereum-tests/BlockchainTests/ValidBlocks/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP1559/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP3675/`
- `ethereum-tests/BlockchainTests/ValidBlocks/bcEIP4844-blobtransactions/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bc4895-withdrawals/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP1559/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcEIP3675/`
- `ethereum-tests/BlockchainTests/InvalidBlocks/bcInvalidHeaderTest/`
- `ethereum-tests/src/BlockchainTestsFiller/`

Execution-spec-tests (current checkout):

- `execution-spec-tests/fixtures/` exists but has no populated blockchain fixture subdirectories in this checkout.
- Blockchain-relevant generated tests are currently under:
  - `execution-spec-tests/tests/paris/`
  - `execution-spec-tests/tests/shanghai/`
  - `execution-spec-tests/tests/cancun/`
  - `execution-spec-tests/tests/prague/`

## Notes for Implementation

- Keep chain management and validation separate and testable.
- Use Voltaire primitives and Voltaire blockchain module directly.
- Keep fork-aware validation gates explicit from Paris -> Shanghai -> Cancun -> Prague.
- Follow Nethermind architecture as a structural reference only; keep Zig code idiomatic and allocation-aware.
