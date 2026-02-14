/// Engine API interface for consensus layer communication.
///
/// Mirrors Nethermind's IEngineRpcModule capability exchange surface and
/// follows the vtable-based dependency injection pattern used in src/host.zig.
const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const method_name = @import("method_name.zig");
const Hardfork = primitives.Hardfork;

const ExchangeCapabilitiesMethod = @FieldType(jsonrpc.engine.EngineMethod, "engine_exchangeCapabilities");
const ExchangeTransitionConfigurationV1Method =
    @FieldType(jsonrpc.engine.EngineMethod, "engine_exchangeTransitionConfigurationV1");
const NewPayloadV1Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_newPayloadV1");
const NewPayloadV2Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_newPayloadV2");
const NewPayloadV3Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_newPayloadV3");
const NewPayloadV4Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_newPayloadV4");
const NewPayloadV5Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_newPayloadV5");
const ForkchoiceUpdatedV1Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_forkchoiceUpdatedV1");
const ForkchoiceUpdatedV2Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_forkchoiceUpdatedV2");
const ForkchoiceUpdatedV3Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_forkchoiceUpdatedV3");
const GetPayloadV1Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadV1");
const GetPayloadV2Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadV2");
const GetPayloadV3Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadV3");
const GetPayloadV4Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadV4");
const GetPayloadV5Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadV5");
const GetPayloadV6Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadV6");
const GetPayloadBodiesByHashV1Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadBodiesByHashV1");
const GetPayloadBodiesByRangeV1Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getPayloadBodiesByRangeV1");
const GetBlobsV1Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getBlobsV1");
const GetBlobsV2Method = @FieldType(jsonrpc.engine.EngineMethod, "engine_getBlobsV2");

const ExchangeCapabilitiesVoltaireParams = @FieldType(ExchangeCapabilitiesMethod, "params");
const ExchangeCapabilitiesVoltaireResult = @FieldType(ExchangeCapabilitiesMethod, "result");
const ExchangeTransitionConfigurationV1VoltaireParams = @FieldType(ExchangeTransitionConfigurationV1Method, "params");
const ExchangeTransitionConfigurationV1VoltaireResult = @FieldType(ExchangeTransitionConfigurationV1Method, "result");
const NewPayloadV1VoltaireParams = @FieldType(NewPayloadV1Method, "params");
const NewPayloadV1VoltaireResult = @FieldType(NewPayloadV1Method, "result");
const NewPayloadV2VoltaireParams = @FieldType(NewPayloadV2Method, "params");
const NewPayloadV2VoltaireResult = @FieldType(NewPayloadV2Method, "result");
const NewPayloadV3VoltaireParams = @FieldType(NewPayloadV3Method, "params");
const NewPayloadV3VoltaireResult = @FieldType(NewPayloadV3Method, "result");
const NewPayloadV4VoltaireParams = @FieldType(NewPayloadV4Method, "params");
const NewPayloadV4VoltaireResult = @FieldType(NewPayloadV4Method, "result");
const NewPayloadV5VoltaireParams = @FieldType(NewPayloadV5Method, "params");
const NewPayloadV5VoltaireResult = @FieldType(NewPayloadV5Method, "result");
const ForkchoiceUpdatedV1VoltaireParams = @FieldType(ForkchoiceUpdatedV1Method, "params");
const ForkchoiceUpdatedV1VoltaireResult = @FieldType(ForkchoiceUpdatedV1Method, "result");
const ForkchoiceUpdatedV2VoltaireParams = @FieldType(ForkchoiceUpdatedV2Method, "params");
const ForkchoiceUpdatedV2VoltaireResult = @FieldType(ForkchoiceUpdatedV2Method, "result");
const ForkchoiceUpdatedV3VoltaireParams = @FieldType(ForkchoiceUpdatedV3Method, "params");
const ForkchoiceUpdatedV3VoltaireResult = @FieldType(ForkchoiceUpdatedV3Method, "result");
const GetPayloadV1VoltaireParams = @FieldType(GetPayloadV1Method, "params");
const GetPayloadV1VoltaireResult = @FieldType(GetPayloadV1Method, "result");
const GetPayloadV2VoltaireParams = @FieldType(GetPayloadV2Method, "params");
const GetPayloadV2VoltaireResult = @FieldType(GetPayloadV2Method, "result");
const GetPayloadV3VoltaireParams = @FieldType(GetPayloadV3Method, "params");
const GetPayloadV3VoltaireResult = @FieldType(GetPayloadV3Method, "result");
const GetPayloadV4VoltaireParams = @FieldType(GetPayloadV4Method, "params");
const GetPayloadV4VoltaireResult = @FieldType(GetPayloadV4Method, "result");
const GetPayloadV5VoltaireParams = @FieldType(GetPayloadV5Method, "params");
const GetPayloadV5VoltaireResult = @FieldType(GetPayloadV5Method, "result");
const GetPayloadV6VoltaireParams = @FieldType(GetPayloadV6Method, "params");
const GetPayloadV6VoltaireResult = @FieldType(GetPayloadV6Method, "result");
const GetPayloadBodiesByHashV1VoltaireParams = @FieldType(GetPayloadBodiesByHashV1Method, "params");
const GetPayloadBodiesByHashV1VoltaireResult = @FieldType(GetPayloadBodiesByHashV1Method, "result");
const GetPayloadBodiesByRangeV1VoltaireParams = @FieldType(GetPayloadBodiesByRangeV1Method, "params");
const GetPayloadBodiesByRangeV1VoltaireResult = @FieldType(GetPayloadBodiesByRangeV1Method, "result");
const GetBlobsV1VoltaireParams = @FieldType(GetBlobsV1Method, "params");
const GetBlobsV1VoltaireResult = @FieldType(GetBlobsV1Method, "result");
const GetBlobsV2VoltaireParams = @FieldType(GetBlobsV2Method, "params");
const GetBlobsV2VoltaireResult = @FieldType(GetBlobsV2Method, "result");

fn runtime_voltaire_type(comptime T: type) type {
    if (comptime @hasDecl(T, "Quantity")) {
        return T.Quantity;
    }

    const info = @typeInfo(T);
    if (info == .@"struct") {
        const s = info.@"struct";
        var fields: [s.fields.len]std.builtin.Type.StructField = undefined;
        inline for (s.fields, 0..) |field, i| {
            fields[i] = .{
                .name = field.name,
                .type = runtime_voltaire_type(field.type),
                .default_value_ptr = field.default_value_ptr,
                .is_comptime = field.is_comptime,
                .alignment = field.alignment,
            };
        }
        return @Type(.{ .@"struct" = .{
            .layout = s.layout,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = s.is_tuple,
        } });
    }

    return T;
}

const Quantity = runtime_voltaire_type(@FieldType(ExchangeCapabilitiesVoltaireParams, "consensus_client_methods"));

/// Request payload type for `engine_exchangeCapabilities`.
pub const ExchangeCapabilitiesParams = runtime_voltaire_type(ExchangeCapabilitiesVoltaireParams);
/// Response payload type for `engine_exchangeCapabilities`.
pub const ExchangeCapabilitiesResult = runtime_voltaire_type(ExchangeCapabilitiesVoltaireResult);

/// ClientVersionV1 per execution-apis/src/engine/identification.md.
pub const ClientVersionV1 = Quantity;

/// Parameters for `engine_getClientVersionV1` requests.
pub const ClientVersionV1Params = struct {
    consensus_client: ClientVersionV1,
};

/// Result payload for `engine_getClientVersionV1` responses.
pub const ClientVersionV1Result = struct {
    value: []const ClientVersionV1,
};

/// Request payload type for `engine_exchangeTransitionConfigurationV1`.
pub const ExchangeTransitionConfigurationV1Params = runtime_voltaire_type(ExchangeTransitionConfigurationV1VoltaireParams);
/// Response payload type for `engine_exchangeTransitionConfigurationV1`.
pub const ExchangeTransitionConfigurationV1Result = runtime_voltaire_type(ExchangeTransitionConfigurationV1VoltaireResult);
/// Request payload type for `engine_newPayloadV1`.
pub const NewPayloadV1Params = runtime_voltaire_type(NewPayloadV1VoltaireParams);
/// Response payload type for `engine_newPayloadV1`.
pub const NewPayloadV1Result = runtime_voltaire_type(NewPayloadV1VoltaireResult);
/// Request payload type for `engine_newPayloadV2`.
pub const NewPayloadV2Params = runtime_voltaire_type(NewPayloadV2VoltaireParams);
/// Response payload type for `engine_newPayloadV2`.
pub const NewPayloadV2Result = runtime_voltaire_type(NewPayloadV2VoltaireResult);
/// Request payload type for `engine_newPayloadV3`.
pub const NewPayloadV3Params = runtime_voltaire_type(NewPayloadV3VoltaireParams);
/// Response payload type for `engine_newPayloadV3`.
pub const NewPayloadV3Result = runtime_voltaire_type(NewPayloadV3VoltaireResult);
/// Request payload type for `engine_newPayloadV4`.
pub const NewPayloadV4Params = runtime_voltaire_type(NewPayloadV4VoltaireParams);
/// Response payload type for `engine_newPayloadV4`.
pub const NewPayloadV4Result = runtime_voltaire_type(NewPayloadV4VoltaireResult);
/// Request payload type for `engine_newPayloadV5`.
pub const NewPayloadV5Params = runtime_voltaire_type(NewPayloadV5VoltaireParams);
/// Response payload type for `engine_newPayloadV5`.
pub const NewPayloadV5Result = runtime_voltaire_type(NewPayloadV5VoltaireResult);
/// Request payload type for `engine_forkchoiceUpdatedV1`.
pub const ForkchoiceUpdatedV1Params = runtime_voltaire_type(ForkchoiceUpdatedV1VoltaireParams);
/// Response payload type for `engine_forkchoiceUpdatedV1`.
pub const ForkchoiceUpdatedV1Result = runtime_voltaire_type(ForkchoiceUpdatedV1VoltaireResult);
/// Request payload type for `engine_forkchoiceUpdatedV2`.
pub const ForkchoiceUpdatedV2Params = runtime_voltaire_type(ForkchoiceUpdatedV2VoltaireParams);
/// Response payload type for `engine_forkchoiceUpdatedV2`.
pub const ForkchoiceUpdatedV2Result = runtime_voltaire_type(ForkchoiceUpdatedV2VoltaireResult);
/// Request payload type for `engine_forkchoiceUpdatedV3`.
pub const ForkchoiceUpdatedV3Params = runtime_voltaire_type(ForkchoiceUpdatedV3VoltaireParams);
/// Response payload type for `engine_forkchoiceUpdatedV3`.
pub const ForkchoiceUpdatedV3Result = runtime_voltaire_type(ForkchoiceUpdatedV3VoltaireResult);
/// Request payload type for `engine_getPayloadV1`.
pub const GetPayloadV1Params = runtime_voltaire_type(GetPayloadV1VoltaireParams);
/// Response payload type for `engine_getPayloadV1`.
pub const GetPayloadV1Result = runtime_voltaire_type(GetPayloadV1VoltaireResult);
/// Request payload type for `engine_getPayloadV2`.
pub const GetPayloadV2Params = runtime_voltaire_type(GetPayloadV2VoltaireParams);
/// Response payload type for `engine_getPayloadV2`.
pub const GetPayloadV2Result = runtime_voltaire_type(GetPayloadV2VoltaireResult);
/// Request payload type for `engine_getPayloadV3`.
pub const GetPayloadV3Params = runtime_voltaire_type(GetPayloadV3VoltaireParams);
/// Response payload type for `engine_getPayloadV3`.
pub const GetPayloadV3Result = runtime_voltaire_type(GetPayloadV3VoltaireResult);
/// Request payload type for `engine_getPayloadV4`.
pub const GetPayloadV4Params = runtime_voltaire_type(GetPayloadV4VoltaireParams);
/// Response payload type for `engine_getPayloadV4`.
pub const GetPayloadV4Result = runtime_voltaire_type(GetPayloadV4VoltaireResult);
/// Request payload type for `engine_getPayloadV5`.
pub const GetPayloadV5Params = runtime_voltaire_type(GetPayloadV5VoltaireParams);
/// Response payload type for `engine_getPayloadV5`.
pub const GetPayloadV5Result = runtime_voltaire_type(GetPayloadV5VoltaireResult);
/// Request payload type for `engine_getPayloadV6`.
pub const GetPayloadV6Params = runtime_voltaire_type(GetPayloadV6VoltaireParams);
/// Response payload type for `engine_getPayloadV6`.
pub const GetPayloadV6Result = runtime_voltaire_type(GetPayloadV6VoltaireResult);
/// Request payload type for `engine_getPayloadBodiesByHashV1`.
pub const GetPayloadBodiesByHashV1Params = runtime_voltaire_type(GetPayloadBodiesByHashV1VoltaireParams);
/// Response payload type for `engine_getPayloadBodiesByHashV1`.
pub const GetPayloadBodiesByHashV1Result = runtime_voltaire_type(GetPayloadBodiesByHashV1VoltaireResult);
/// Request payload type for `engine_getPayloadBodiesByRangeV1`.
pub const GetPayloadBodiesByRangeV1Params = runtime_voltaire_type(GetPayloadBodiesByRangeV1VoltaireParams);
/// Response payload type for `engine_getPayloadBodiesByRangeV1`.
pub const GetPayloadBodiesByRangeV1Result = runtime_voltaire_type(GetPayloadBodiesByRangeV1VoltaireResult);
/// Request payload type for `engine_getBlobsV1`.
pub const GetBlobsV1Params = runtime_voltaire_type(GetBlobsV1VoltaireParams);
/// Response payload type for `engine_getBlobsV1`.
pub const GetBlobsV1Result = runtime_voltaire_type(GetBlobsV1VoltaireResult);
/// Request payload type for `engine_getBlobsV2`.
pub const GetBlobsV2Params = runtime_voltaire_type(GetBlobsV2VoltaireParams);
/// Response payload type for `engine_getBlobsV2`.
pub const GetBlobsV2Result = runtime_voltaire_type(GetBlobsV2VoltaireResult);

fn dispatch_result(comptime Method: type) type {
    if (Method == ExchangeCapabilitiesMethod) return ExchangeCapabilitiesResult;
    if (Method == ExchangeTransitionConfigurationV1Method) return ExchangeTransitionConfigurationV1Result;
    if (Method == NewPayloadV1Method) return NewPayloadV1Result;
    if (Method == NewPayloadV2Method) return NewPayloadV2Result;
    if (Method == NewPayloadV3Method) return NewPayloadV3Result;
    if (Method == NewPayloadV4Method) return NewPayloadV4Result;
    if (Method == NewPayloadV5Method) return NewPayloadV5Result;
    if (Method == ForkchoiceUpdatedV1Method) return ForkchoiceUpdatedV1Result;
    if (Method == ForkchoiceUpdatedV2Method) return ForkchoiceUpdatedV2Result;
    if (Method == ForkchoiceUpdatedV3Method) return ForkchoiceUpdatedV3Result;
    if (Method == GetPayloadV1Method) return GetPayloadV1Result;
    if (Method == GetPayloadV2Method) return GetPayloadV2Result;
    if (Method == GetPayloadV3Method) return GetPayloadV3Result;
    if (Method == GetPayloadV4Method) return GetPayloadV4Result;
    if (Method == GetPayloadV5Method) return GetPayloadV5Result;
    if (Method == GetPayloadV6Method) return GetPayloadV6Result;
    if (Method == GetPayloadBodiesByHashV1Method) return GetPayloadBodiesByHashV1Result;
    if (Method == GetPayloadBodiesByRangeV1Method) return GetPayloadBodiesByRangeV1Result;
    if (Method == GetBlobsV1Method) return GetBlobsV1Result;
    if (Method == GetBlobsV2Method) return GetBlobsV2Result;
    return @FieldType(Method, "result");
}

const supported_capability_method_names_static = [_][]const u8{
    "engine_getClientVersionV1",
    "engine_exchangeTransitionConfigurationV1",
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_newPayloadV3",
    "engine_newPayloadV4",
    "engine_newPayloadV5",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_forkchoiceUpdatedV3",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
    "engine_getPayloadV3",
    "engine_getPayloadV4",
    "engine_getPayloadV5",
    "engine_getPayloadV6",
    "engine_getPayloadBodiesByHashV1",
    "engine_getPayloadBodiesByRangeV1",
    "engine_getBlobsV1",
    "engine_getBlobsV2",
};

/// Returns the Engine API method names this EL surface currently supports.
///
/// Per execution-apis/common.md, `engine_exchangeCapabilities` is intentionally
/// excluded from the advertised response list.
pub fn supported_capability_method_names() []const []const u8 {
    return supported_capability_method_names_static[0..];
}

/// Minimal fork/spec feature flags used to derive Engine capability advertising.
///
/// Mirrors Nethermind's capability gating inputs (withdrawals, 4844, requests,
/// op-isthmus, 7594), with an explicit Amsterdam toggle for V5/V6 method names
/// currently present in the Voltaire Engine method catalog.
pub const EngineCapabilitiesSpecState = struct {
    withdrawals_enabled: bool,
    eip4844_enabled: bool,
    requests_enabled: bool,
    op_isthmus_enabled: bool = false,
    eip7594_enabled: bool,
    amsterdam_enabled: bool = false,

    /// Derive capability feature flags from a canonical Voltaire hardfork.
    pub fn from_hardfork(hardfork: Hardfork) EngineCapabilitiesSpecState {
        return .{
            .withdrawals_enabled = hardfork.isAtLeast(.SHANGHAI),
            .eip4844_enabled = hardfork.hasEIP4844(),
            .requests_enabled = hardfork.isAtLeast(.PRAGUE),
            .op_isthmus_enabled = false,
            .eip7594_enabled = hardfork.isAtLeast(.OSAKA),
            .amsterdam_enabled = false,
        };
    }
};

/// Fork/spec-aware provider for `engine_exchangeCapabilities` response methods.
///
/// This unit reuses `supported_capability_method_names()` as the source catalog
/// and filters it according to the enabled spec features.
pub const EngineCapabilitiesProvider = struct {
    spec_state: EngineCapabilitiesSpecState,

    pub const Error = error{NoSpace};

    /// Writes enabled capability names into `out` and returns the used prefix.
    ///
    /// Callers should size `out` to at least `supported_capability_method_names().len`
    /// to avoid `error.NoSpace`.
    pub fn enabled_capability_method_names(
        self: EngineCapabilitiesProvider,
        out: [][]const u8,
    ) Error![]const []const u8 {
        var count: usize = 0;
        for (supported_capability_method_names()) |method| {
            if (!self.is_enabled(method)) continue;
            if (count >= out.len) return error.NoSpace;
            out[count] = method;
            count += 1;
        }
        return out[0..count];
    }

    fn is_enabled(self: EngineCapabilitiesProvider, method: []const u8) bool {
        if (std.mem.eql(u8, method, "engine_getClientVersionV1") or
            std.mem.eql(u8, method, "engine_exchangeTransitionConfigurationV1") or
            std.mem.eql(u8, method, "engine_newPayloadV1") or
            std.mem.eql(u8, method, "engine_forkchoiceUpdatedV1") or
            std.mem.eql(u8, method, "engine_getPayloadV1"))
        {
            return true;
        }

        if (std.mem.eql(u8, method, "engine_newPayloadV2") or
            std.mem.eql(u8, method, "engine_forkchoiceUpdatedV2") or
            std.mem.eql(u8, method, "engine_getPayloadV2") or
            std.mem.eql(u8, method, "engine_getPayloadBodiesByHashV1") or
            std.mem.eql(u8, method, "engine_getPayloadBodiesByRangeV1"))
        {
            return self.spec_state.withdrawals_enabled;
        }

        if (std.mem.eql(u8, method, "engine_newPayloadV3") or
            std.mem.eql(u8, method, "engine_forkchoiceUpdatedV3") or
            std.mem.eql(u8, method, "engine_getPayloadV3") or
            std.mem.eql(u8, method, "engine_getBlobsV1"))
        {
            return self.spec_state.eip4844_enabled;
        }

        if (std.mem.eql(u8, method, "engine_newPayloadV4") or
            std.mem.eql(u8, method, "engine_getPayloadV4"))
        {
            return self.spec_state.requests_enabled or self.spec_state.op_isthmus_enabled;
        }

        if (std.mem.eql(u8, method, "engine_getPayloadV5") or
            std.mem.eql(u8, method, "engine_getBlobsV2"))
        {
            return self.spec_state.eip7594_enabled;
        }

        if (std.mem.eql(u8, method, "engine_newPayloadV5") or
            std.mem.eql(u8, method, "engine_getPayloadV6"))
        {
            return self.spec_state.amsterdam_enabled;
        }

        return false;
    }
};

fn is_supported_capability_method_name(name: []const u8) bool {
    for (supported_capability_method_names_static) |method| {
        if (std.mem.eql(u8, method, name)) return true;
    }
    return false;
}

fn is_valid_supported_response_capability(name: []const u8) bool {
    return method_name.is_valid_advertisable_engine_method_name(name) and
        is_supported_capability_method_name(name);
}

// Method-name validation logic is centralized in client/engine/method_name.zig

/// Vtable-based Engine API interface.
///
/// Exposes `engine_exchangeCapabilities` and
/// `engine_exchangeTransitionConfigurationV1`. Each handler validates its
/// inputs/outputs per execution-apis: capability lists must be engine_*
/// and versioned (and responses must exclude `engine_exchangeCapabilities`).
pub const EngineApi = struct {
    /// Type-erased pointer to the concrete Engine API implementation.
    ptr: *anyopaque,
    /// Pointer to the static vtable for the concrete Engine API implementation.
    vtable: *const VTable,

    /// Errors surfaced by Engine API handlers.
    ///
    /// These map to Engine API JSON-RPC error responses at the RPC layer.
    pub const Error = error{
        /// -32700: Invalid JSON was received by the server.
        ParseError,
        /// -32600: The JSON sent is not a valid Request object.
        InvalidRequest,
        /// -32601: The method does not exist / is not available.
        MethodNotFound,
        /// -32602: Invalid method parameter(s).
        InvalidParams,
        /// -32603: Internal JSON-RPC error.
        InternalError,
        /// -32000: Generic client error while processing request.
        ServerError,
        /// -38001: Payload does not exist / is not available.
        UnknownPayload,
        /// -38002: Forkchoice state is invalid / inconsistent.
        InvalidForkchoiceState,
        /// -38003: Payload attributes are invalid / inconsistent.
        InvalidPayloadAttributes,
        /// -38004: Number of requested entities is too large.
        TooLargeRequest,
        /// -38005: Payload belongs to a fork that is not supported.
        UnsupportedFork,
    };

    /// Engine API error codes per execution-apis common definitions.
    pub const ErrorCode = struct {
        /// JSON-RPC error code integer type.
        /// Use plain i32 to avoid an unnecessary re-export indirection.
        pub const Code = i32;

        /// -32700: Invalid JSON was received by the server.
        pub const parse_error: Code = -32700;
        /// -32600: The JSON sent is not a valid Request object.
        pub const invalid_request: Code = -32600;
        /// -32601: The method does not exist / is not available.
        pub const method_not_found: Code = -32601;
        /// -32602: Invalid method parameter(s).
        pub const invalid_params: Code = -32602;
        /// -32603: Internal JSON-RPC error.
        pub const internal_error: Code = -32603;
        /// -32000: Generic client error while processing request.
        pub const server_error: Code = -32000;
        /// -38001: Payload does not exist / is not available.
        pub const unknown_payload: Code = -38001;
        /// -38002: Forkchoice state is invalid / inconsistent.
        pub const invalid_forkchoice_state: Code = -38002;
        /// -38003: Payload attributes are invalid / inconsistent.
        pub const invalid_payload_attributes: Code = -38003;
        /// -38004: Number of requested entities is too large.
        pub const too_large_request: Code = -38004;
        /// -38005: Payload belongs to a fork that is not supported.
        pub const unsupported_fork: Code = -38005;
    };

    /// Virtual function table for Engine API operations.
    pub const VTable = struct {
        /// Exchange list of supported Engine API methods.
        exchange_capabilities: *const fn (
            ptr: *anyopaque,
            params: ExchangeCapabilitiesParams,
        ) Error!ExchangeCapabilitiesResult,
        /// Return execution layer client version information.
        get_client_version_v1: *const fn (
            ptr: *anyopaque,
            params: ClientVersionV1Params,
        ) Error!ClientVersionV1Result,
        /// Exchange transition configuration for Paris (EIP-3675).
        /// Note: Deprecated since Cancun; retained for compatibility per execution-apis.
        exchange_transition_configuration_v1: *const fn (
            ptr: *anyopaque,
            params: ExchangeTransitionConfigurationV1Params,
        ) Error!ExchangeTransitionConfigurationV1Result,
        /// Validate an incoming execution payload V1.
        new_payload_v1: *const fn (
            ptr: *anyopaque,
            params: NewPayloadV1Params,
        ) Error!NewPayloadV1Result,
        /// Validate an incoming execution payload V2.
        new_payload_v2: *const fn (
            ptr: *anyopaque,
            params: NewPayloadV2Params,
        ) Error!NewPayloadV2Result,
        /// Validate an incoming execution payload V3.
        new_payload_v3: *const fn (
            ptr: *anyopaque,
            params: NewPayloadV3Params,
        ) Error!NewPayloadV3Result,
        /// Validate an incoming execution payload V4.
        new_payload_v4: *const fn (
            ptr: *anyopaque,
            params: NewPayloadV4Params,
        ) Error!NewPayloadV4Result,
        /// Validate an incoming execution payload V5.
        new_payload_v5: *const fn (
            ptr: *anyopaque,
            params: NewPayloadV5Params,
        ) Error!NewPayloadV5Result,
        /// Updates forkchoice state and optionally starts payload building (V1).
        forkchoice_updated_v1: *const fn (
            ptr: *anyopaque,
            params: ForkchoiceUpdatedV1Params,
        ) Error!ForkchoiceUpdatedV1Result,
        /// Updates forkchoice state and optionally starts payload building (V2).
        forkchoice_updated_v2: *const fn (
            ptr: *anyopaque,
            params: ForkchoiceUpdatedV2Params,
        ) Error!ForkchoiceUpdatedV2Result,
        /// Updates forkchoice state and optionally starts payload building (V3).
        forkchoice_updated_v3: *const fn (
            ptr: *anyopaque,
            params: ForkchoiceUpdatedV3Params,
        ) Error!ForkchoiceUpdatedV3Result,
        /// Returns a built execution payload by payload ID (V1).
        get_payload_v1: *const fn (
            ptr: *anyopaque,
            params: GetPayloadV1Params,
        ) Error!GetPayloadV1Result,
        /// Returns a built execution payload plus block value by payload ID (V2).
        get_payload_v2: *const fn (
            ptr: *anyopaque,
            params: GetPayloadV2Params,
        ) Error!GetPayloadV2Result,
        /// Returns a built execution payload plus sidecars by payload ID (V3).
        get_payload_v3: *const fn (
            ptr: *anyopaque,
            params: GetPayloadV3Params,
        ) Error!GetPayloadV3Result,
        /// Returns a built execution payload plus sidecars/requests by payload ID (V4).
        get_payload_v4: *const fn (
            ptr: *anyopaque,
            params: GetPayloadV4Params,
        ) Error!GetPayloadV4Result,
        /// Returns a built execution payload plus sidecars/requests by payload ID (V5).
        get_payload_v5: *const fn (
            ptr: *anyopaque,
            params: GetPayloadV5Params,
        ) Error!GetPayloadV5Result,
        /// Returns a built execution payload plus sidecars/requests by payload ID (V6).
        get_payload_v6: *const fn (
            ptr: *anyopaque,
            params: GetPayloadV6Params,
        ) Error!GetPayloadV6Result,
        /// Returns execution payload bodies by block hash.
        get_payload_bodies_by_hash_v1: *const fn (
            ptr: *anyopaque,
            params: GetPayloadBodiesByHashV1Params,
        ) Error!GetPayloadBodiesByHashV1Result,
        /// Returns execution payload bodies by block range.
        get_payload_bodies_by_range_v1: *const fn (
            ptr: *anyopaque,
            params: GetPayloadBodiesByRangeV1Params,
        ) Error!GetPayloadBodiesByRangeV1Result,
        /// Returns blob pool entries by versioned hash.
        get_blobs_v1: *const fn (
            ptr: *anyopaque,
            params: GetBlobsV1Params,
        ) Error!GetBlobsV1Result,
        /// Returns blob pool entries by versioned hash with Osaka response model.
        get_blobs_v2: *const fn (
            ptr: *anyopaque,
            params: GetBlobsV2Params,
        ) Error!GetBlobsV2Result,
    };

    /// Exchange list of supported Engine API methods.
    /// Enforces spec invariants (versioned methods; response excludes engine_exchangeCapabilities).
    pub fn exchange_capabilities(
        self: EngineApi,
        params: ExchangeCapabilitiesParams,
    ) Error!ExchangeCapabilitiesResult {
        try validate_capabilities(params.consensus_client_methods, Error.InvalidParams);
        const result = try self.vtable.exchange_capabilities(self.ptr, params);
        // Response list must satisfy full advertisable rules
        try validate_response_capabilities(result.value, Error.InternalError);
        return result;
    }

    /// Returns execution client version information for `engine_getClientVersionV1`.
    pub fn get_client_version_v1(
        self: EngineApi,
        params: ClientVersionV1Params,
    ) Error!ClientVersionV1Result {
        try validate_client_version_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.get_client_version_v1(self.ptr, params);
        try validate_client_version_v1_result(result, Error.InternalError);
        return result;
    }

    /// Exchanges transition configuration with the consensus client.
    /// Validates JSON shapes per execution-apis Paris spec (TransitionConfigurationV1).
    pub fn exchange_transition_configuration_v1(
        self: EngineApi,
        params: ExchangeTransitionConfigurationV1Params,
    ) Error!ExchangeTransitionConfigurationV1Result {
        try validate_transition_configuration_params(params, Error.InvalidParams);
        const result = try self.vtable.exchange_transition_configuration_v1(self.ptr, params);
        try validate_transition_configuration_result(result, Error.InternalError);
        return result;
    }

    /// Validates and imports an execution payload V1.
    ///
    /// This stage performs request/response shape checks only.
    /// Full payload semantics are handled by the execution path.
    pub fn new_payload_v1(
        self: EngineApi,
        params: NewPayloadV1Params,
    ) Error!NewPayloadV1Result {
        try validate_new_payload_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.new_payload_v1(self.ptr, params);
        try validate_new_payload_v1_result(result, Error.InternalError);
        return result;
    }

    /// Validates and imports an execution payload V2.
    ///
    /// This stage performs request/response shape checks only.
    /// Full payload semantics are handled by the execution path.
    pub fn new_payload_v2(
        self: EngineApi,
        params: NewPayloadV2Params,
    ) Error!NewPayloadV2Result {
        try validate_new_payload_v2_params(params, Error.InvalidParams);
        const result = try self.vtable.new_payload_v2(self.ptr, params);
        try validate_new_payload_v2_result(result, Error.InternalError);
        return result;
    }

    /// Validates and imports an execution payload V3.
    pub fn new_payload_v3(
        self: EngineApi,
        params: NewPayloadV3Params,
    ) Error!NewPayloadV3Result {
        try validate_new_payload_v3_params(params, Error.InvalidParams);
        const result = try self.vtable.new_payload_v3(self.ptr, params);
        try validate_new_payload_v3_result(result, Error.InternalError);
        return result;
    }

    /// Validates and imports an execution payload V4.
    pub fn new_payload_v4(
        self: EngineApi,
        params: NewPayloadV4Params,
    ) Error!NewPayloadV4Result {
        try validate_new_payload_v4_params(params, Error.InvalidParams);
        const result = try self.vtable.new_payload_v4(self.ptr, params);
        try validate_new_payload_v4_result(result, Error.InternalError);
        return result;
    }

    /// Validates and imports an execution payload V5.
    pub fn new_payload_v5(
        self: EngineApi,
        params: NewPayloadV5Params,
    ) Error!NewPayloadV5Result {
        try validate_new_payload_v5_params(params, Error.InvalidParams);
        const result = try self.vtable.new_payload_v5(self.ptr, params);
        try validate_new_payload_v5_result(result, Error.InternalError);
        return result;
    }

    /// Applies a forkchoice update V1 with optional payload attributes.
    ///
    /// This stage performs request/response shape checks only.
    /// Forkchoice/payload semantics are handled by the execution path.
    pub fn forkchoice_updated_v1(
        self: EngineApi,
        params: ForkchoiceUpdatedV1Params,
    ) Error!ForkchoiceUpdatedV1Result {
        try validate_forkchoice_updated_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.forkchoice_updated_v1(self.ptr, params);
        try validate_forkchoice_updated_v1_result(result, Error.InternalError);
        return result;
    }

    /// Applies a forkchoice update V2 with optional payload attributes.
    pub fn forkchoice_updated_v2(
        self: EngineApi,
        params: ForkchoiceUpdatedV2Params,
    ) Error!ForkchoiceUpdatedV2Result {
        try validate_forkchoice_updated_v2_params(params, Error.InvalidParams);
        const result = try self.vtable.forkchoice_updated_v2(self.ptr, params);
        try validate_forkchoice_updated_v2_result(result, Error.InternalError);
        return result;
    }

    /// Applies a forkchoice update V3 with optional payload attributes.
    pub fn forkchoice_updated_v3(
        self: EngineApi,
        params: ForkchoiceUpdatedV3Params,
    ) Error!ForkchoiceUpdatedV3Result {
        try validate_forkchoice_updated_v3_params(params, Error.InvalidParams);
        const result = try self.vtable.forkchoice_updated_v3(self.ptr, params);
        try validate_forkchoice_updated_v3_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves an `ExecutionPayloadV1` by 8-byte `payloadId`.
    ///
    /// This stage performs request/response shape checks only.
    pub fn get_payload_v1(
        self: EngineApi,
        params: GetPayloadV1Params,
    ) Error!GetPayloadV1Result {
        try validate_get_payload_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_v1(self.ptr, params);
        try validate_get_payload_v1_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves an execution payload response object by 8-byte `payloadId` (V2).
    ///
    /// This stage performs request/response shape checks only.
    pub fn get_payload_v2(
        self: EngineApi,
        params: GetPayloadV2Params,
    ) Error!GetPayloadV2Result {
        try validate_get_payload_v2_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_v2(self.ptr, params);
        try validate_get_payload_v2_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves an execution payload response object by 8-byte `payloadId` (V3).
    pub fn get_payload_v3(
        self: EngineApi,
        params: GetPayloadV3Params,
    ) Error!GetPayloadV3Result {
        try validate_get_payload_v3_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_v3(self.ptr, params);
        try validate_get_payload_v3_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves an execution payload response object by 8-byte `payloadId` (V4).
    pub fn get_payload_v4(
        self: EngineApi,
        params: GetPayloadV4Params,
    ) Error!GetPayloadV4Result {
        try validate_get_payload_v4_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_v4(self.ptr, params);
        try validate_get_payload_v4_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves an execution payload response object by 8-byte `payloadId` (V5).
    pub fn get_payload_v5(
        self: EngineApi,
        params: GetPayloadV5Params,
    ) Error!GetPayloadV5Result {
        try validate_get_payload_v5_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_v5(self.ptr, params);
        try validate_get_payload_v5_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves an execution payload response object by 8-byte `payloadId` (V6).
    pub fn get_payload_v6(
        self: EngineApi,
        params: GetPayloadV6Params,
    ) Error!GetPayloadV6Result {
        try validate_get_payload_v6_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_v6(self.ptr, params);
        try validate_get_payload_v6_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves execution payload bodies by block hash.
    pub fn get_payload_bodies_by_hash_v1(
        self: EngineApi,
        params: GetPayloadBodiesByHashV1Params,
    ) Error!GetPayloadBodiesByHashV1Result {
        try validate_get_payload_bodies_by_hash_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_bodies_by_hash_v1(self.ptr, params);
        try validate_get_payload_bodies_by_hash_v1_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves execution payload bodies by starting block and range size.
    pub fn get_payload_bodies_by_range_v1(
        self: EngineApi,
        params: GetPayloadBodiesByRangeV1Params,
    ) Error!GetPayloadBodiesByRangeV1Result {
        try validate_get_payload_bodies_by_range_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.get_payload_bodies_by_range_v1(self.ptr, params);
        try validate_get_payload_bodies_by_range_v1_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves blobs from the local blob pool.
    pub fn get_blobs_v1(
        self: EngineApi,
        params: GetBlobsV1Params,
    ) Error!GetBlobsV1Result {
        try validate_get_blobs_v1_params(params, Error.InvalidParams);
        const result = try self.vtable.get_blobs_v1(self.ptr, params);
        try validate_get_blobs_v1_result(result, Error.InternalError);
        return result;
    }

    /// Retrieves blobs from the local blob pool using Osaka response schema.
    pub fn get_blobs_v2(
        self: EngineApi,
        params: GetBlobsV2Params,
    ) Error!GetBlobsV2Result {
        try validate_get_blobs_v2_params(params, Error.InvalidParams);
        const result = try self.vtable.get_blobs_v2(self.ptr, params);
        try validate_get_blobs_v2_result(result, Error.InternalError);
        return result;
    }

    /// Generic dispatcher for EngineMethod calls using Voltaire's EngineMethod schema.
    ///
    /// Example:
    /// const Result = try api.dispatch("engine_exchangeCapabilities", params);
    pub fn dispatch(
        self: EngineApi,
        comptime Method: type,
        params: anytype,
    ) Error!dispatch_result(Method) {
        if (comptime Method == ExchangeCapabilitiesMethod) {
            return self.exchange_capabilities(params);
        } else if (comptime Method == ExchangeTransitionConfigurationV1Method) {
            return self.exchange_transition_configuration_v1(params);
        } else if (comptime Method == NewPayloadV1Method) {
            return self.new_payload_v1(params);
        } else if (comptime Method == NewPayloadV2Method) {
            return self.new_payload_v2(params);
        } else if (comptime Method == NewPayloadV3Method) {
            return self.new_payload_v3(params);
        } else if (comptime Method == NewPayloadV4Method) {
            return self.new_payload_v4(params);
        } else if (comptime Method == NewPayloadV5Method) {
            return self.new_payload_v5(params);
        } else if (comptime Method == ForkchoiceUpdatedV1Method) {
            return self.forkchoice_updated_v1(params);
        } else if (comptime Method == ForkchoiceUpdatedV2Method) {
            return self.forkchoice_updated_v2(params);
        } else if (comptime Method == ForkchoiceUpdatedV3Method) {
            return self.forkchoice_updated_v3(params);
        } else if (comptime Method == GetPayloadV1Method) {
            return self.get_payload_v1(params);
        } else if (comptime Method == GetPayloadV2Method) {
            return self.get_payload_v2(params);
        } else if (comptime Method == GetPayloadV3Method) {
            return self.get_payload_v3(params);
        } else if (comptime Method == GetPayloadV4Method) {
            return self.get_payload_v4(params);
        } else if (comptime Method == GetPayloadV5Method) {
            return self.get_payload_v5(params);
        } else if (comptime Method == GetPayloadV6Method) {
            return self.get_payload_v6(params);
        } else if (comptime Method == GetPayloadBodiesByHashV1Method) {
            return self.get_payload_bodies_by_hash_v1(params);
        } else if (comptime Method == GetPayloadBodiesByRangeV1Method) {
            return self.get_payload_bodies_by_range_v1(params);
        } else if (comptime Method == GetBlobsV1Method) {
            return self.get_blobs_v1(params);
        } else if (comptime Method == GetBlobsV2Method) {
            return self.get_blobs_v2(params);
        } else {
            return Error.MethodNotFound;
        }
    }
};

fn validate_string_list(list: anytype, comptime invalid_err: EngineApi.Error, comptime pred: fn ([]const u8) bool) EngineApi.Error!void {
    const ListType = @TypeOf(list);
    if (comptime @hasField(ListType, "value")) return validate_string_list(list.value, invalid_err, pred);
    if (comptime is_slice_of_byte_slices(ListType)) {
        for (list) |name| if (!pred(name)) return invalid_err;
        return;
    }
    if (comptime ListType == std.json.Value) return validate_json_string_array(list, invalid_err, pred);
    return invalid_err;
}

fn validate_capabilities(list: anytype, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    return validate_string_list(list, invalid_err, method_name.is_engine_versioned_method_name);
}

/// Validate a JSON array of strings using `pred`.
/// Returns `invalid_err` if the JSON shape is invalid or any entry fails `pred`.
fn validate_json_string_array(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
    comptime pred: fn ([]const u8) bool,
) EngineApi.Error!void {
    if (value != .array) return invalid_err;
    const items = value.array.items;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        if (item != .string) return invalid_err;
        if (!pred(item.string)) return invalid_err;
    }
}

fn validate_response_capabilities(list: anytype, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    return validate_string_list(list, invalid_err, is_valid_supported_response_capability);
}

fn validate_client_version_v1_params(params: ClientVersionV1Params, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    try validate_client_version_v1(params.consensus_client, invalid_err);
}

fn validate_client_version_v1_result(result: ClientVersionV1Result, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    if (result.value.len == 0) return invalid_err;
    for (result.value) |client| {
        try validate_client_version_v1(client, invalid_err);
    }
}

fn validate_client_version_v1(client: ClientVersionV1, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    const v = client.value;
    if (v != .object) return invalid_err;
    const obj = v.object;
    const code_val = obj.get("code") orelse return invalid_err;
    if (code_val != .string) return invalid_err;
    if (code_val.string.len != 2) return invalid_err;
    // Enforce two ASCII letters for ClientCode per identification.md examples.
    // Accept either case to accommodate future additions.
    {
        const s = code_val.string;
        inline for (0..2) |i| {
            const c = s[i];
            if (!(std.ascii.isAlphabetic(c))) return invalid_err;
        }
    }

    // name: required string
    const name_val = obj.get("name") orelse return invalid_err;
    if (name_val != .string) return invalid_err;
    // version: required string
    const version_val = obj.get("version") orelse return invalid_err;
    if (version_val != .string) return invalid_err;

    const commit_val = obj.get("commit") orelse return invalid_err;
    if (commit_val != .string) return invalid_err;
    // Must be 0x-prefixed 4-byte DATA, per spec.
    try validate_data_hex_exact_size(commit_val.string, 4, invalid_err);
}

fn validate_transition_configuration_params(
    params: ExchangeTransitionConfigurationV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    // Voltaire JSON-RPC typing wraps dynamic values in Quantity.value: std.json.Value
    return validate_transition_configuration_json(params.consensus_client_configuration.value, invalid_err);
}

fn validate_transition_configuration_result(
    result: ExchangeTransitionConfigurationV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    return validate_transition_configuration_json(result.value.value, invalid_err);
}

fn validate_transition_configuration_json(value: std.json.Value, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    // TransitionConfigurationV1 object with fields:
    // - terminalTotalDifficulty: QUANTITY (u256)
    // - terminalBlockHash: DATA (32 bytes)
    // - terminalBlockNumber: QUANTITY (u64)
    if (value != .object) return invalid_err;

    const obj = value.object;

    const ttd_val = obj.get("terminalTotalDifficulty") orelse return invalid_err;
    const tbh_val = obj.get("terminalBlockHash") orelse return invalid_err;
    const tbn_val = obj.get("terminalBlockNumber") orelse return invalid_err;

    // Validate terminalTotalDifficulty as QUANTITY (hex) parsable to u256
    switch (ttd_val) {
        .string => |s| _ = try parse_quantity_hex_u256(s, invalid_err),
        else => return invalid_err,
    }

    // Validate terminalBlockHash is 32-byte DATA hex string
    switch (tbh_val) {
        .string => |s| try validate_data_hex_exact_size(s, 32, invalid_err),
        else => return invalid_err,
    }

    // Validate terminalBlockNumber fits in 64-bit QUANTITY
    switch (tbn_val) {
        .string => |s| _ = try parse_quantity_hex_u64(s, invalid_err),
        else => return invalid_err,
    }
}

fn validate_new_payload_v1_params(
    params: NewPayloadV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v1_json(params.execution_payload.value, invalid_err);
}

fn validate_new_payload_v1_result(
    result: NewPayloadV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_status_v1_json(result.value.value, invalid_err, is_payload_status_v1_status);
}

fn validate_new_payload_v2_params(
    params: NewPayloadV2Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v1_or_v2_json(params.execution_payload.value, invalid_err);
    try validate_execution_payload_v2_version_gate_json(params.execution_payload.value, invalid_err);
}

fn validate_new_payload_v2_result(
    result: NewPayloadV2Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_status_without_invalid_block_hash(result.value.value, invalid_err);
}

fn validate_new_payload_v3_params(
    params: NewPayloadV3Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v3_json(params.execution_payload.value, invalid_err);
    try validate_hash32_array_json(params.expected_blob_versioned_hashes.value, invalid_err);
    try validate_hash32_value_json(params.root_of_the_parent_beacon_block.value, invalid_err);
}

fn validate_new_payload_v3_result(
    result: NewPayloadV3Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_status_without_invalid_block_hash(result.value.value, invalid_err);
}

fn validate_new_payload_v4_params(
    params: NewPayloadV4Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v3_json(params.execution_payload.value, invalid_err);
    try validate_hash32_array_json(params.expected_blob_versioned_hashes.value, invalid_err);
    try validate_hash32_value_json(params.root_of_the_parent_beacon_block.value, invalid_err);
    try validate_bytes_array_json(params.execution_requests.value, invalid_err);
}

fn validate_new_payload_v4_result(
    result: NewPayloadV4Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_status_without_invalid_block_hash(result.value.value, invalid_err);
}

fn validate_new_payload_v5_params(
    params: NewPayloadV5Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v4_json(params.execution_payload.value, invalid_err);
    try validate_hash32_array_json(params.expected_blob_versioned_hashes.value, invalid_err);
    try validate_hash32_value_json(params.parent_beacon_block_root.value, invalid_err);
    try validate_bytes_array_json(params.execution_requests.value, invalid_err);
}

fn validate_new_payload_v5_result(
    result: NewPayloadV5Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_status_without_invalid_block_hash(result.value.value, invalid_err);
}

fn validate_execution_payload_v2_version_gate_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    // engine_newPayloadV2 only allows ExecutionPayloadV1 or ExecutionPayloadV2.
    if (obj.get("blobGasUsed") != null) return invalid_err;
    if (obj.get("excessBlobGas") != null) return invalid_err;
    if (obj.get("blockAccessList") != null) return invalid_err;
    if (obj.get("slotNumber") != null) return invalid_err;
}

fn validate_forkchoice_updated_v1_params(
    params: ForkchoiceUpdatedV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_forkchoice_state_v1_json(params.forkchoice_state.value, invalid_err);
    switch (params.payload_attributes.value) {
        .object => try validate_payload_attributes_v1_json(params.payload_attributes.value, invalid_err),
        .null => {},
        else => return invalid_err,
    }
}

fn validate_forkchoice_updated_v1_result(
    result: ForkchoiceUpdatedV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_forkchoice_updated_result_json(result.value.value, invalid_err);
}

fn validate_forkchoice_updated_v2_params(
    params: ForkchoiceUpdatedV2Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_forkchoice_state_v1_json(params.forkchoice_state.value, invalid_err);
    switch (params.payload_attributes.value) {
        .object => try validate_payload_attributes_v1_or_v2_json(params.payload_attributes.value, invalid_err),
        .null => {},
        else => return invalid_err,
    }
}

fn validate_forkchoice_updated_v2_result(
    result: ForkchoiceUpdatedV2Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_forkchoice_updated_result_json(result.value.value, invalid_err);
}

fn validate_forkchoice_updated_v3_params(
    params: ForkchoiceUpdatedV3Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_forkchoice_state_v1_json(params.forkchoice_state.value, invalid_err);
    switch (params.payload_attributes.value) {
        .object => try validate_payload_attributes_v3_json(params.payload_attributes.value, invalid_err),
        .null => {},
        else => return invalid_err,
    }
}

fn validate_forkchoice_updated_v3_result(
    result: ForkchoiceUpdatedV3Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_forkchoice_updated_result_json(result.value.value, invalid_err);
}

fn validate_forkchoice_updated_result_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    const payload_status = obj.get("payloadStatus") orelse return invalid_err;
    try validate_payload_status_v1_json(payload_status, invalid_err, is_restricted_payload_status_v1_status);

    const payload_id = obj.get("payloadId") orelse return invalid_err;
    switch (payload_id) {
        .null => {},
        .string => |s| try validate_data_hex_exact_size(s, 8, invalid_err),
        else => return invalid_err,
    }
}

fn validate_get_payload_v1_params(
    params: GetPayloadV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_id_json(params.payload_id.value, invalid_err);
}

fn validate_get_payload_v1_result(
    result: GetPayloadV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v1_json(result.value.value, invalid_err);
}

fn validate_get_payload_v2_params(
    params: GetPayloadV2Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_id_json(params.payload_id.value, invalid_err);
}

fn validate_get_payload_v2_result(
    result: GetPayloadV2Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (result.value.value != .object) return invalid_err;
    const obj = result.value.value.object;

    const execution_payload = obj.get("executionPayload") orelse return invalid_err;
    try validate_execution_payload_v1_or_v2_json(execution_payload, invalid_err);

    const block_value = obj.get("blockValue") orelse return invalid_err;
    switch (block_value) {
        .string => |s| _ = try parse_quantity_hex_u256(s, invalid_err),
        else => return invalid_err,
    }
}

fn validate_payload_id_json(
    payload_id: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    switch (payload_id) {
        .string => |s| try validate_data_hex_exact_size(s, 8, invalid_err),
        else => return invalid_err,
    }
}

fn validate_get_payload_v3_params(
    params: GetPayloadV3Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_id_json(params.payload_id.value, invalid_err);
}

fn validate_get_payload_v3_result(
    result: GetPayloadV3Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_get_payload_v3_or_v4_or_v5_json(result.value.value, invalid_err, false, false);
}

fn validate_get_payload_v4_params(
    params: GetPayloadV4Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_id_json(params.payload_id.value, invalid_err);
}

fn validate_get_payload_v4_result(
    result: GetPayloadV4Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_get_payload_v3_or_v4_or_v5_json(result.value.value, invalid_err, true, false);
}

fn validate_get_payload_v5_params(
    params: GetPayloadV5Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_id_json(params.payload_id.value, invalid_err);
}

fn validate_get_payload_v5_result(
    result: GetPayloadV5Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_get_payload_v3_or_v4_or_v5_json(result.value.value, invalid_err, true, true);
}

fn validate_get_payload_v6_params(
    params: GetPayloadV6Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_id_json(params.payload_id.value, invalid_err);
}

fn validate_get_payload_v6_result(
    result: GetPayloadV6Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (result.value.value != .object) return invalid_err;
    const obj = result.value.value.object;

    const execution_payload = obj.get("executionPayload") orelse return invalid_err;
    try validate_execution_payload_v4_json(execution_payload, invalid_err);

    const block_value = obj.get("blockValue") orelse return invalid_err;
    switch (block_value) {
        .string => |s| _ = try parse_quantity_hex_u256(s, invalid_err),
        else => return invalid_err,
    }

    const blobs_bundle = obj.get("blobsBundle") orelse return invalid_err;
    try validate_blobs_bundle_v2_json(blobs_bundle, invalid_err);

    const should_override_builder = obj.get("shouldOverrideBuilder") orelse return invalid_err;
    if (should_override_builder != .bool) return invalid_err;

    const execution_requests = obj.get("executionRequests") orelse return invalid_err;
    try validate_bytes_array_json(execution_requests, invalid_err);
}

fn validate_get_payload_bodies_by_hash_v1_params(
    params: GetPayloadBodiesByHashV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_hash32_array_json(params.array_of_block_hashes.value, invalid_err);
}

fn validate_get_payload_bodies_by_hash_v1_result(
    result: GetPayloadBodiesByHashV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_bodies_array_json(result.value.value, invalid_err);
}

fn validate_get_payload_bodies_by_range_v1_params(
    params: GetPayloadBodiesByRangeV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    switch (params.starting_block_number.value) {
        .string => |s| _ = try parse_quantity_hex_u64(s, invalid_err),
        else => return invalid_err,
    }
    switch (params.number_of_blocks_to_return.value) {
        .string => |s| _ = try parse_quantity_hex_u64(s, invalid_err),
        else => return invalid_err,
    }
}

fn validate_get_payload_bodies_by_range_v1_result(
    result: GetPayloadBodiesByRangeV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_bodies_array_json(result.value.value, invalid_err);
}

fn validate_get_blobs_v1_params(
    params: GetBlobsV1Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_hash32_array_json(params.blob_versioned_hashes.value, invalid_err);
}

fn validate_get_blobs_v1_result(
    result: GetBlobsV1Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_blob_and_proof_array_json(result.value.value, invalid_err, false);
}

fn validate_get_blobs_v2_params(
    params: GetBlobsV2Params,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_hash32_array_json(params.blob_versioned_hashes.value, invalid_err);
}

fn validate_get_blobs_v2_result(
    result: GetBlobsV2Result,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_blob_and_proof_array_json(result.value.value, invalid_err, true);
}

fn validate_get_payload_v3_or_v4_or_v5_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
    comptime requires_execution_requests: bool,
    comptime use_blobs_bundle_v2: bool,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    const execution_payload = obj.get("executionPayload") orelse return invalid_err;
    try validate_execution_payload_v3_json(execution_payload, invalid_err);

    const block_value = obj.get("blockValue") orelse return invalid_err;
    switch (block_value) {
        .string => |s| _ = try parse_quantity_hex_u256(s, invalid_err),
        else => return invalid_err,
    }

    const blobs_bundle = obj.get("blobsBundle") orelse return invalid_err;
    if (comptime use_blobs_bundle_v2) {
        try validate_blobs_bundle_v2_json(blobs_bundle, invalid_err);
    } else {
        try validate_blobs_bundle_v1_json(blobs_bundle, invalid_err);
    }

    const should_override_builder = obj.get("shouldOverrideBuilder") orelse return invalid_err;
    if (should_override_builder != .bool) return invalid_err;

    if (comptime requires_execution_requests) {
        const execution_requests = obj.get("executionRequests") orelse return invalid_err;
        try validate_bytes_array_json(execution_requests, invalid_err);
    }
}

fn validate_execution_payload_v1_or_v2_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v1_json(value, invalid_err);
    if (value != .object) return invalid_err;

    const withdrawals = value.object.get("withdrawals") orelse return;
    try validate_withdrawals_v1_json(withdrawals, invalid_err);
}

fn validate_execution_payload_v3_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v1_or_v2_json(value, invalid_err);
    if (value != .object) return invalid_err;
    const obj = value.object;
    try validate_json_quantity_u64_field(obj, "blobGasUsed", invalid_err);
    try validate_json_quantity_u64_field(obj, "excessBlobGas", invalid_err);
    if (obj.get("blockAccessList") != null) return invalid_err;
    if (obj.get("slotNumber") != null) return invalid_err;
}

fn validate_execution_payload_v4_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_execution_payload_v3_json(value, invalid_err);
    if (value != .object) return invalid_err;
    const obj = value.object;
    try validate_json_data_max_size_field(obj, "blockAccessList", std.math.maxInt(usize) / 2, invalid_err);
    try validate_json_quantity_u64_field(obj, "slotNumber", invalid_err);
}

fn validate_hash32_array_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .array) return invalid_err;
    for (value.array.items) |item| {
        switch (item) {
            .string => |s| try validate_data_hex_exact_size(s, 32, invalid_err),
            else => return invalid_err,
        }
    }
}

fn validate_bytes_array_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .array) return invalid_err;
    for (value.array.items) |item| {
        switch (item) {
            .string => |s| try validate_data_hex_max_size(s, std.math.maxInt(usize) / 2, invalid_err),
            else => return invalid_err,
        }
    }
}

fn validate_blobs_bundle_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    const commitments = obj.get("commitments") orelse return invalid_err;
    if (commitments != .array) return invalid_err;
    for (commitments.array.items) |commitment| {
        switch (commitment) {
            .string => |s| try validate_data_hex_exact_size(s, 48, invalid_err),
            else => return invalid_err,
        }
    }

    const proofs = obj.get("proofs") orelse return invalid_err;
    if (proofs != .array) return invalid_err;
    for (proofs.array.items) |proof| {
        switch (proof) {
            .string => |s| try validate_data_hex_exact_size(s, 48, invalid_err),
            else => return invalid_err,
        }
    }

    const blobs = obj.get("blobs") orelse return invalid_err;
    try validate_bytes_array_json(blobs, invalid_err);
}

fn validate_blobs_bundle_v2_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_blobs_bundle_v1_json(value, invalid_err);
}

fn validate_payload_bodies_array_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .array) return invalid_err;
    for (value.array.items) |body| {
        try validate_payload_body_v1_json(body, invalid_err);
    }
}

fn validate_payload_body_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    const txs = obj.get("transactions") orelse return invalid_err;
    try validate_bytes_array_json(txs, invalid_err);

    if (obj.get("withdrawals")) |withdrawals| {
        switch (withdrawals) {
            .null => {},
            .array => try validate_withdrawals_v1_json(withdrawals, invalid_err),
            else => return invalid_err,
        }
    }
}

fn validate_blob_and_proof_array_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
    comptime with_cell_proofs: bool,
) EngineApi.Error!void {
    if (value != .array) return invalid_err;
    for (value.array.items) |entry| {
        if (entry != .object) return invalid_err;
        const obj = entry.object;
        const blob = obj.get("blob") orelse return invalid_err;
        switch (blob) {
            .string => |s| try validate_data_hex_max_size(s, std.math.maxInt(usize) / 2, invalid_err),
            else => return invalid_err,
        }

        if (comptime with_cell_proofs) {
            const proofs = obj.get("proofs") orelse return invalid_err;
            if (proofs != .array) return invalid_err;
            for (proofs.array.items) |proof| {
                switch (proof) {
                    .string => |s| try validate_data_hex_exact_size(s, 48, invalid_err),
                    else => return invalid_err,
                }
            }
        } else {
            const proof = obj.get("proof") orelse return invalid_err;
            switch (proof) {
                .string => |s| try validate_data_hex_exact_size(s, 48, invalid_err),
                else => return invalid_err,
            }
        }
    }
}

fn validate_withdrawals_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .array) return invalid_err;
    for (value.array.items) |withdrawal| {
        try validate_withdrawal_v1_json(withdrawal, invalid_err);
    }
}

fn validate_withdrawal_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;
    try validate_json_quantity_u64_field(obj, "index", invalid_err);
    try validate_json_quantity_u64_field(obj, "validatorIndex", invalid_err);
    try validate_json_fixed_data_field(obj, "address", 20, invalid_err);
    try validate_json_quantity_u64_field(obj, "amount", invalid_err);
}

fn validate_execution_payload_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    // Required fields per execution-apis Paris ExecutionPayloadV1
    try validate_json_fixed_data_field(obj, "parentHash", 32, invalid_err);
    try validate_json_fixed_data_field(obj, "feeRecipient", 20, invalid_err);
    try validate_json_fixed_data_field(obj, "stateRoot", 32, invalid_err);
    try validate_json_fixed_data_field(obj, "receiptsRoot", 32, invalid_err);
    try validate_json_fixed_data_field(obj, "logsBloom", 256, invalid_err);
    try validate_json_fixed_data_field(obj, "prevRandao", 32, invalid_err);
    try validate_json_quantity_u64_field(obj, "blockNumber", invalid_err);
    try validate_json_quantity_u64_field(obj, "gasLimit", invalid_err);
    try validate_json_quantity_u64_field(obj, "gasUsed", invalid_err);
    try validate_json_quantity_u64_field(obj, "timestamp", invalid_err);
    try validate_json_data_max_size_field(obj, "extraData", 32, invalid_err);
    try validate_json_quantity_u256_field(obj, "baseFeePerGas", invalid_err);
    try validate_json_fixed_data_field(obj, "blockHash", 32, invalid_err);

    const txs = obj.get("transactions") orelse return invalid_err;
    if (txs != .array) return invalid_err;
    for (txs.array.items) |tx| {
        if (tx != .string) return invalid_err;
        try validate_data_hex_max_size(tx.string, std.math.maxInt(usize) / 2, invalid_err);
    }
}

fn validate_json_fixed_data_field(
    obj: std.json.ObjectMap,
    field_name: []const u8,
    size_bytes: usize,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    const value = obj.get(field_name) orelse return invalid_err;
    switch (value) {
        .string => |s| try validate_data_hex_exact_size(s, size_bytes, invalid_err),
        else => return invalid_err,
    }
}

fn validate_json_data_max_size_field(
    obj: std.json.ObjectMap,
    field_name: []const u8,
    max_size_bytes: usize,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    const value = obj.get(field_name) orelse return invalid_err;
    switch (value) {
        .string => |s| try validate_data_hex_max_size(s, max_size_bytes, invalid_err),
        else => return invalid_err,
    }
}

fn validate_json_quantity_u64_field(
    obj: std.json.ObjectMap,
    field_name: []const u8,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    const value = obj.get(field_name) orelse return invalid_err;
    switch (value) {
        .string => |s| _ = try parse_quantity_hex_u64(s, invalid_err),
        else => return invalid_err,
    }
}

fn validate_json_quantity_u256_field(
    obj: std.json.ObjectMap,
    field_name: []const u8,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    const value = obj.get(field_name) orelse return invalid_err;
    switch (value) {
        .string => |s| _ = try parse_quantity_hex_u256(s, invalid_err),
        else => return invalid_err,
    }
}

fn parse_quantity_hex_u256(
    quantity: []const u8,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!u256 {
    _ = primitives.Hex.validate(quantity) catch return invalid_err;
    if (quantity.len <= 2) return invalid_err;

    const digits = quantity[2..];
    if (digits[0] == '0' and digits.len != 1) return invalid_err;

    return primitives.Hex.hexToU256(quantity) catch return invalid_err;
}

fn parse_quantity_hex_u64(
    quantity: []const u8,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!u64 {
    const parsed = try parse_quantity_hex_u256(quantity, invalid_err);
    if (parsed > std.math.maxInt(u64)) return invalid_err;
    return @intCast(parsed);
}

fn validate_data_hex_exact_size(
    data: []const u8,
    expected_size_bytes: usize,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    _ = primitives.Hex.validate(data) catch return invalid_err;
    const hex_digits_len = data.len - 2;
    if (hex_digits_len % 2 != 0) return invalid_err;
    if (hex_digits_len != expected_size_bytes * 2) return invalid_err;
}

fn validate_data_hex_max_size(
    data: []const u8,
    max_size_bytes: usize,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    _ = primitives.Hex.validate(data) catch return invalid_err;
    const hex_digits_len = data.len - 2;
    if (hex_digits_len % 2 != 0) return invalid_err;
    if (hex_digits_len > max_size_bytes * 2) return invalid_err;
}

fn validate_hash32_value_json(value: std.json.Value, comptime invalid_err: EngineApi.Error) EngineApi.Error!void {
    switch (value) {
        .string => |s| try validate_data_hex_exact_size(s, 32, invalid_err),
        else => return invalid_err,
    }
}

fn validate_payload_status_without_invalid_block_hash(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_status_v1_json(value, invalid_err, is_payload_status_no_invalid_block_hash_status);
}

fn validate_payload_status_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
    comptime status_pred: fn ([]const u8) bool,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;

    const status = obj.get("status") orelse return invalid_err;
    if (status != .string) return invalid_err;
    if (!status_pred(status.string)) return invalid_err;

    const latest_valid_hash = obj.get("latestValidHash") orelse return invalid_err;
    const is_latest_valid_hash_null = switch (latest_valid_hash) {
        .null => true,
        .string => |s| blk: {
            try validate_data_hex_exact_size(s, 32, invalid_err);
            break :blk false;
        },
        else => return invalid_err,
    };

    const validation_error = obj.get("validationError") orelse return invalid_err;
    const is_validation_error_null = switch (validation_error) {
        .null => true,
        .string => false,
        else => return invalid_err,
    };

    if (std.mem.eql(u8, status.string, "VALID")) {
        if (is_latest_valid_hash_null or !is_validation_error_null) return invalid_err;
        return;
    }

    if (std.mem.eql(u8, status.string, "SYNCING") or std.mem.eql(u8, status.string, "ACCEPTED")) {
        if (!is_latest_valid_hash_null or !is_validation_error_null) return invalid_err;
        return;
    }

    if (std.mem.eql(u8, status.string, "INVALID_BLOCK_HASH")) {
        if (!is_latest_valid_hash_null) return invalid_err;
    }
}

fn is_payload_status_v1_status(status: []const u8) bool {
    return std.mem.eql(u8, status, "VALID") or
        std.mem.eql(u8, status, "INVALID") or
        std.mem.eql(u8, status, "SYNCING") or
        std.mem.eql(u8, status, "ACCEPTED") or
        std.mem.eql(u8, status, "INVALID_BLOCK_HASH");
}

fn is_payload_status_no_invalid_block_hash_status(status: []const u8) bool {
    return std.mem.eql(u8, status, "VALID") or
        std.mem.eql(u8, status, "INVALID") or
        std.mem.eql(u8, status, "SYNCING") or
        std.mem.eql(u8, status, "ACCEPTED");
}

fn is_restricted_payload_status_v1_status(status: []const u8) bool {
    return std.mem.eql(u8, status, "VALID") or
        std.mem.eql(u8, status, "INVALID") or
        std.mem.eql(u8, status, "SYNCING");
}

fn validate_forkchoice_state_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;
    try validate_json_fixed_data_field(obj, "headBlockHash", 32, invalid_err);
    try validate_json_fixed_data_field(obj, "safeBlockHash", 32, invalid_err);
    try validate_json_fixed_data_field(obj, "finalizedBlockHash", 32, invalid_err);
}

fn validate_payload_attributes_v1_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    const obj = value.object;
    try validate_json_quantity_u64_field(obj, "timestamp", invalid_err);
    try validate_json_fixed_data_field(obj, "prevRandao", 32, invalid_err);
    try validate_json_fixed_data_field(obj, "suggestedFeeRecipient", 20, invalid_err);
}

fn validate_payload_attributes_v1_or_v2_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    if (value != .object) return invalid_err;
    if (value.object.get("withdrawals") != null) {
        return validate_payload_attributes_v2_json(value, invalid_err);
    }
    return validate_payload_attributes_v1_json(value, invalid_err);
}

fn validate_payload_attributes_v2_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_attributes_v1_json(value, invalid_err);
    if (value != .object) return invalid_err;
    const obj = value.object;
    const withdrawals = obj.get("withdrawals") orelse return invalid_err;
    try validate_withdrawals_v1_json(withdrawals, invalid_err);
}

fn validate_payload_attributes_v3_json(
    value: std.json.Value,
    comptime invalid_err: EngineApi.Error,
) EngineApi.Error!void {
    try validate_payload_attributes_v2_json(value, invalid_err);
    if (value != .object) return invalid_err;
    const obj = value.object;
    try validate_json_fixed_data_field(obj, "parentBeaconBlockRoot", 32, invalid_err);
}

fn is_slice_of_byte_slices(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .slice) return false;
    const child_info = @typeInfo(info.pointer.child);
    if (child_info != .pointer or child_info.pointer.size != .slice) return false;
    return child_info.pointer.child == u8;
}

fn has_method(methods: []const []const u8, needle: []const u8) bool {
    for (methods) |method| {
        if (std.mem.eql(u8, method, needle)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "engine api error codes match engine api spec" {
    const Code = EngineApi.ErrorCode.Code;
    try std.testing.expectEqual(@as(Code, -32700), EngineApi.ErrorCode.parse_error);
    try std.testing.expectEqual(@as(Code, -32600), EngineApi.ErrorCode.invalid_request);
    try std.testing.expectEqual(@as(Code, -32601), EngineApi.ErrorCode.method_not_found);
    try std.testing.expectEqual(@as(Code, -32602), EngineApi.ErrorCode.invalid_params);
    try std.testing.expectEqual(@as(Code, -32603), EngineApi.ErrorCode.internal_error);
    try std.testing.expectEqual(@as(Code, -32000), EngineApi.ErrorCode.server_error);
    try std.testing.expectEqual(@as(Code, -38001), EngineApi.ErrorCode.unknown_payload);
    try std.testing.expectEqual(@as(Code, -38002), EngineApi.ErrorCode.invalid_forkchoice_state);
    try std.testing.expectEqual(@as(Code, -38003), EngineApi.ErrorCode.invalid_payload_attributes);
    try std.testing.expectEqual(@as(Code, -38004), EngineApi.ErrorCode.too_large_request);
    try std.testing.expectEqual(@as(Code, -38005), EngineApi.ErrorCode.unsupported_fork);
}

test "engine api supported capabilities are advertisable and unique" {
    const methods = supported_capability_method_names();
    try std.testing.expect(methods.len != 0);

    var has_get_client_version = false;
    for (methods, 0..) |method, i| {
        try std.testing.expect(method_name.is_valid_advertisable_engine_method_name(method));
        if (std.mem.eql(u8, method, "engine_getClientVersionV1")) {
            has_get_client_version = true;
        }
        for (methods[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, method, other));
        }
    }

    try std.testing.expect(has_get_client_version);
}

test "engine capability spec state derives flags from hardfork" {
    const merge = EngineCapabilitiesSpecState.from_hardfork(.MERGE);
    try std.testing.expect(!merge.withdrawals_enabled);
    try std.testing.expect(!merge.eip4844_enabled);
    try std.testing.expect(!merge.requests_enabled);
    try std.testing.expect(!merge.eip7594_enabled);
    try std.testing.expect(!merge.amsterdam_enabled);

    const shanghai = EngineCapabilitiesSpecState.from_hardfork(.SHANGHAI);
    try std.testing.expect(shanghai.withdrawals_enabled);
    try std.testing.expect(!shanghai.eip4844_enabled);

    const cancun = EngineCapabilitiesSpecState.from_hardfork(.CANCUN);
    try std.testing.expect(cancun.withdrawals_enabled);
    try std.testing.expect(cancun.eip4844_enabled);
    try std.testing.expect(!cancun.requests_enabled);

    const prague = EngineCapabilitiesSpecState.from_hardfork(.PRAGUE);
    try std.testing.expect(prague.requests_enabled);
    try std.testing.expect(!prague.eip7594_enabled);

    const osaka = EngineCapabilitiesSpecState.from_hardfork(.OSAKA);
    try std.testing.expect(osaka.eip7594_enabled);
}

test "engine capabilities provider filters methods by fork/spec features" {
    var out: [supported_capability_method_names_static.len][]const u8 = undefined;

    const merge_provider = EngineCapabilitiesProvider{
        .spec_state = EngineCapabilitiesSpecState.from_hardfork(.MERGE),
    };
    const merge_methods = try merge_provider.enabled_capability_method_names(out[0..]);
    try std.testing.expect(has_method(merge_methods, "engine_getPayloadV1"));
    try std.testing.expect(!has_method(merge_methods, "engine_newPayloadV2"));
    try std.testing.expect(!has_method(merge_methods, "engine_newPayloadV5"));

    const prague_provider = EngineCapabilitiesProvider{
        .spec_state = EngineCapabilitiesSpecState.from_hardfork(.PRAGUE),
    };
    const prague_methods = try prague_provider.enabled_capability_method_names(out[0..]);
    try std.testing.expect(has_method(prague_methods, "engine_newPayloadV4"));
    try std.testing.expect(has_method(prague_methods, "engine_getPayloadV4"));
    try std.testing.expect(!has_method(prague_methods, "engine_getPayloadV5"));
    try std.testing.expect(!has_method(prague_methods, "engine_newPayloadV5"));

    var amsterdam_state = EngineCapabilitiesSpecState.from_hardfork(.OSAKA);
    amsterdam_state.amsterdam_enabled = true;
    const amsterdam_provider = EngineCapabilitiesProvider{
        .spec_state = amsterdam_state,
    };
    const amsterdam_methods = try amsterdam_provider.enabled_capability_method_names(out[0..]);
    try std.testing.expect(has_method(amsterdam_methods, "engine_getPayloadV5"));
    try std.testing.expect(has_method(amsterdam_methods, "engine_getBlobsV2"));
    try std.testing.expect(has_method(amsterdam_methods, "engine_newPayloadV5"));
    try std.testing.expect(has_method(amsterdam_methods, "engine_getPayloadV6"));
}

test "engine capabilities provider enables v4 methods when op-isthmus is enabled" {
    var out: [supported_capability_method_names_static.len][]const u8 = undefined;
    const provider = EngineCapabilitiesProvider{
        .spec_state = .{
            .withdrawals_enabled = true,
            .eip4844_enabled = true,
            .requests_enabled = false,
            .op_isthmus_enabled = true,
            .eip7594_enabled = false,
        },
    };

    const methods = try provider.enabled_capability_method_names(out[0..]);
    try std.testing.expect(has_method(methods, "engine_newPayloadV4"));
    try std.testing.expect(has_method(methods, "engine_getPayloadV4"));
}

test "engine capabilities provider returns NoSpace when output is too small" {
    var out: [1][]const u8 = undefined;
    const provider = EngineCapabilitiesProvider{
        .spec_state = EngineCapabilitiesSpecState.from_hardfork(.MERGE),
    };

    try std.testing.expectError(error.NoSpace, provider.enabled_capability_method_names(out[0..]));
}

fn deinit_methods_payload(payload: anytype) void {
    if (payload.array) |*array| array.deinit();
}

fn make_json_methods_array(allocator: std.mem.Allocator, methods: []const []const u8) !std.json.Array {
    var array = std.json.Array.init(allocator);
    for (methods) |method| {
        try array.append(.{ .string = method });
    }
    return array;
}

fn make_methods_payload(comptime MethodsType: type, allocator: std.mem.Allocator, methods: []const []const u8) !struct {
    array: ?std.json.Array,
    value: MethodsType,
} {
    if (comptime is_slice_of_byte_slices(MethodsType)) {
        return .{ .array = null, .value = methods };
    }

    if (comptime MethodsType == std.json.Value) {
        const array = try make_json_methods_array(allocator, methods);
        return .{ .array = array, .value = .{ .array = array } };
    }

    if (comptime @hasField(MethodsType, "value") or MethodsType == Quantity) {
        const array = try make_json_methods_array(allocator, methods);
        const val: std.json.Value = .{ .array = array };
        const typed = try std.json.innerParseFromValue(MethodsType, allocator, val, .{});
        return .{ .array = array, .value = typed };
    }

    @compileError("Unsupported Engine API capability list type");
}

const ConsensusType = @FieldType(ExchangeCapabilitiesParams, "consensus_client_methods");
const ResultType = @FieldType(ExchangeCapabilitiesResult, "value");
fn make_dummy_client_version(allocator: std.mem.Allocator) !ClientVersionV1 {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("code", .{ .string = "GM" });
    try obj.put("name", .{ .string = "guillotine-mini" });
    try obj.put("version", .{ .string = "0.0.0" });
    try obj.put("commit", .{ .string = "0x00000000" });
    const val: std.json.Value = .{ .object = obj };
    return try std.json.innerParseFromValue(ClientVersionV1, allocator, val, .{});
}

const DummyEngine = struct {
    const Self = @This();
    result: ExchangeCapabilitiesResult,
    client_version_result: ClientVersionV1Result = undefined,
    transition_result: ExchangeTransitionConfigurationV1Result = undefined,
    new_payload_result: NewPayloadV1Result = undefined,
    new_payload_v2_result: NewPayloadV2Result = undefined,
    new_payload_v3_result: NewPayloadV3Result = undefined,
    new_payload_v4_result: NewPayloadV4Result = undefined,
    new_payload_v5_result: NewPayloadV5Result = undefined,
    forkchoice_updated_result: ForkchoiceUpdatedV1Result = undefined,
    forkchoice_updated_v2_result: ForkchoiceUpdatedV2Result = undefined,
    forkchoice_updated_v3_result: ForkchoiceUpdatedV3Result = undefined,
    get_payload_result: GetPayloadV1Result = undefined,
    get_payload_v2_result: GetPayloadV2Result = undefined,
    get_payload_v3_result: GetPayloadV3Result = undefined,
    get_payload_v4_result: GetPayloadV4Result = undefined,
    get_payload_v5_result: GetPayloadV5Result = undefined,
    get_payload_v6_result: GetPayloadV6Result = undefined,
    get_payload_bodies_by_hash_v1_result: GetPayloadBodiesByHashV1Result = undefined,
    get_payload_bodies_by_range_v1_result: GetPayloadBodiesByRangeV1Result = undefined,
    get_blobs_v1_result: GetBlobsV1Result = undefined,
    get_blobs_v2_result: GetBlobsV2Result = undefined,
    called: bool = false,
    client_version_called: bool = false,
    transition_called: bool = false,
    new_payload_called: bool = false,
    new_payload_v2_called: bool = false,
    new_payload_v3_called: bool = false,
    new_payload_v4_called: bool = false,
    new_payload_v5_called: bool = false,
    forkchoice_updated_called: bool = false,
    forkchoice_updated_v2_called: bool = false,
    forkchoice_updated_v3_called: bool = false,
    get_payload_called: bool = false,
    get_payload_v2_called: bool = false,
    get_payload_v3_called: bool = false,
    get_payload_v4_called: bool = false,
    get_payload_v5_called: bool = false,
    get_payload_v6_called: bool = false,
    get_payload_bodies_by_hash_v1_called: bool = false,
    get_payload_bodies_by_range_v1_called: bool = false,
    get_blobs_v1_called: bool = false,
    get_blobs_v2_called: bool = false,

    fn exchange_capabilities(
        ptr: *anyopaque,
        params: ExchangeCapabilitiesParams,
    ) EngineApi.Error!ExchangeCapabilitiesResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.called = true;
        return self.result;
    }

    fn get_client_version_v1(
        ptr: *anyopaque,
        params: ClientVersionV1Params,
    ) EngineApi.Error!ClientVersionV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.client_version_called = true;
        return self.client_version_result;
    }

    fn exchange_transition_configuration_v1(
        ptr: *anyopaque,
        params: ExchangeTransitionConfigurationV1Params,
    ) EngineApi.Error!ExchangeTransitionConfigurationV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.transition_called = true;
        return self.transition_result;
    }

    fn new_payload_v1(
        ptr: *anyopaque,
        params: NewPayloadV1Params,
    ) EngineApi.Error!NewPayloadV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.new_payload_called = true;
        return self.new_payload_result;
    }

    fn new_payload_v2(
        ptr: *anyopaque,
        params: NewPayloadV2Params,
    ) EngineApi.Error!NewPayloadV2Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.new_payload_v2_called = true;
        return self.new_payload_v2_result;
    }

    fn new_payload_v3(
        ptr: *anyopaque,
        params: NewPayloadV3Params,
    ) EngineApi.Error!NewPayloadV3Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.new_payload_v3_called = true;
        return self.new_payload_v3_result;
    }

    fn new_payload_v4(
        ptr: *anyopaque,
        params: NewPayloadV4Params,
    ) EngineApi.Error!NewPayloadV4Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.new_payload_v4_called = true;
        return self.new_payload_v4_result;
    }

    fn new_payload_v5(
        ptr: *anyopaque,
        params: NewPayloadV5Params,
    ) EngineApi.Error!NewPayloadV5Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.new_payload_v5_called = true;
        return self.new_payload_v5_result;
    }

    fn forkchoice_updated_v1(
        ptr: *anyopaque,
        params: ForkchoiceUpdatedV1Params,
    ) EngineApi.Error!ForkchoiceUpdatedV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.forkchoice_updated_called = true;
        return self.forkchoice_updated_result;
    }

    fn forkchoice_updated_v2(
        ptr: *anyopaque,
        params: ForkchoiceUpdatedV2Params,
    ) EngineApi.Error!ForkchoiceUpdatedV2Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.forkchoice_updated_v2_called = true;
        return self.forkchoice_updated_v2_result;
    }

    fn forkchoice_updated_v3(
        ptr: *anyopaque,
        params: ForkchoiceUpdatedV3Params,
    ) EngineApi.Error!ForkchoiceUpdatedV3Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.forkchoice_updated_v3_called = true;
        return self.forkchoice_updated_v3_result;
    }

    fn get_payload_v1(
        ptr: *anyopaque,
        params: GetPayloadV1Params,
    ) EngineApi.Error!GetPayloadV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_called = true;
        return self.get_payload_result;
    }

    fn get_payload_v2(
        ptr: *anyopaque,
        params: GetPayloadV2Params,
    ) EngineApi.Error!GetPayloadV2Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_v2_called = true;
        return self.get_payload_v2_result;
    }

    fn get_payload_v3(
        ptr: *anyopaque,
        params: GetPayloadV3Params,
    ) EngineApi.Error!GetPayloadV3Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_v3_called = true;
        return self.get_payload_v3_result;
    }

    fn get_payload_v4(
        ptr: *anyopaque,
        params: GetPayloadV4Params,
    ) EngineApi.Error!GetPayloadV4Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_v4_called = true;
        return self.get_payload_v4_result;
    }

    fn get_payload_v5(
        ptr: *anyopaque,
        params: GetPayloadV5Params,
    ) EngineApi.Error!GetPayloadV5Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_v5_called = true;
        return self.get_payload_v5_result;
    }

    fn get_payload_v6(
        ptr: *anyopaque,
        params: GetPayloadV6Params,
    ) EngineApi.Error!GetPayloadV6Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_v6_called = true;
        return self.get_payload_v6_result;
    }

    fn get_payload_bodies_by_hash_v1(
        ptr: *anyopaque,
        params: GetPayloadBodiesByHashV1Params,
    ) EngineApi.Error!GetPayloadBodiesByHashV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_bodies_by_hash_v1_called = true;
        return self.get_payload_bodies_by_hash_v1_result;
    }

    fn get_payload_bodies_by_range_v1(
        ptr: *anyopaque,
        params: GetPayloadBodiesByRangeV1Params,
    ) EngineApi.Error!GetPayloadBodiesByRangeV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_payload_bodies_by_range_v1_called = true;
        return self.get_payload_bodies_by_range_v1_result;
    }

    fn get_blobs_v1(
        ptr: *anyopaque,
        params: GetBlobsV1Params,
    ) EngineApi.Error!GetBlobsV1Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_blobs_v1_called = true;
        return self.get_blobs_v1_result;
    }

    fn get_blobs_v2(
        ptr: *anyopaque,
        params: GetBlobsV2Params,
    ) EngineApi.Error!GetBlobsV2Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = params;
        self.get_blobs_v2_called = true;
        return self.get_blobs_v2_result;
    }
};

const dummy_vtable = EngineApi.VTable{
    .exchange_capabilities = DummyEngine.exchange_capabilities,
    .get_client_version_v1 = DummyEngine.get_client_version_v1,
    .exchange_transition_configuration_v1 = DummyEngine.exchange_transition_configuration_v1,
    .new_payload_v1 = DummyEngine.new_payload_v1,
    .new_payload_v2 = DummyEngine.new_payload_v2,
    .new_payload_v3 = DummyEngine.new_payload_v3,
    .new_payload_v4 = DummyEngine.new_payload_v4,
    .new_payload_v5 = DummyEngine.new_payload_v5,
    .forkchoice_updated_v1 = DummyEngine.forkchoice_updated_v1,
    .forkchoice_updated_v2 = DummyEngine.forkchoice_updated_v2,
    .forkchoice_updated_v3 = DummyEngine.forkchoice_updated_v3,
    .get_payload_v1 = DummyEngine.get_payload_v1,
    .get_payload_v2 = DummyEngine.get_payload_v2,
    .get_payload_v3 = DummyEngine.get_payload_v3,
    .get_payload_v4 = DummyEngine.get_payload_v4,
    .get_payload_v5 = DummyEngine.get_payload_v5,
    .get_payload_v6 = DummyEngine.get_payload_v6,
    .get_payload_bodies_by_hash_v1 = DummyEngine.get_payload_bodies_by_hash_v1,
    .get_payload_bodies_by_range_v1 = DummyEngine.get_payload_bodies_by_range_v1,
    .get_blobs_v1 = DummyEngine.get_blobs_v1,
    .get_blobs_v2 = DummyEngine.get_blobs_v2,
};

fn make_api(dummy: *DummyEngine) EngineApi {
    return EngineApi{ .ptr = dummy, .vtable = &dummy_vtable };
}

test "engine api dispatches capabilities exchange" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
        "engine_forkchoiceUpdatedV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    // initialize default client_version_result using dummy client JSON
    {
        const alloc = std.testing.allocator;
        const client_const = try make_dummy_client_version(alloc);
        var client = client_const; // allow deinit of inner ObjectMap
        defer if (client.value == .object) client.value.object.deinit();
        dummy.client_version_result = .{ .value = &[_]ClientVersionV1{client_const} };
    }
    const api = make_api(&dummy);

    const result = try api.exchange_capabilities(params);
    try std.testing.expect(dummy.called);
    try std.testing.expectEqualDeep(result_value, result);
}

test "engine api rejects unversioned consensus capabilities" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayload",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_capabilities(params));
    try std.testing.expect(!dummy.called);
}

test "engine api rejects non-engine consensus capabilities" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "eth_getBlockByNumberV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_capabilities(params));
    try std.testing.expect(!dummy.called);
}

test "engine api allows unknown engine consensus capabilities" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_fooV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    _ = try api.exchange_capabilities(params);
    try std.testing.expect(dummy.called);
}

test "engine api rejects non-array consensus capabilities payload" {
    const allocator = std.testing.allocator;
    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = Quantity{ .value = .{ .string = "engine_newPayloadV1" } },
    };

    var dummy = DummyEngine{ .result = .{ .value = result_payload.value } };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_capabilities(params));
    try std.testing.expect(!dummy.called);
}

test "engine api rejects non-string consensus capabilities entries" {
    const allocator = std.testing.allocator;

    var invalid_array = std.json.Array.init(allocator);
    defer invalid_array.deinit();
    try invalid_array.append(.{ .bool = true });
    try invalid_array.append(.{ .string = "engine_newPayloadV1" });

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = Quantity{ .value = .{ .array = invalid_array } },
    };

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    var dummy = DummyEngine{ .result = .{ .value = result_payload.value } };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_capabilities(params));
    try std.testing.expect(!dummy.called);
}

test "engine api rejects response containing exchangeCapabilities" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_exchangeCapabilities",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.exchange_capabilities(params));
    try std.testing.expect(dummy.called);
}

test "engine api rejects response containing non-engine methods" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    // Execution client must not advertise non-engine namespace methods
    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "eth_getBlockByNumberV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    // Violation must surface as InternalError (bad executor response)
    try std.testing.expectError(EngineApi.Error.InternalError, api.exchange_capabilities(params));
    try std.testing.expect(dummy.called);
}

test "engine api rejects response containing unversioned engine methods" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    // Execution client must only advertise versioned engine_* methods
    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayload",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    // Violation must surface as InternalError (bad executor response)
    try std.testing.expectError(EngineApi.Error.InternalError, api.exchange_capabilities(params));
    try std.testing.expect(dummy.called);
}

test "engine api rejects response containing unsupported engine methods" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_fooV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{
        .consensus_client_methods = consensus_payload.value,
    };
    const result_value = ExchangeCapabilitiesResult{
        .value = result_payload.value,
    };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.exchange_capabilities(params));
    try std.testing.expect(dummy.called);
}

test "engine api dispatches client version exchange" {
    const alloc = std.testing.allocator;
    var obj = std.json.ObjectMap.init(alloc);
    defer obj.deinit();
    try obj.put("code", .{ .string = "LS" });
    try obj.put("name", .{ .string = "Lodestar" });
    try obj.put("version", .{ .string = "v1.2.3" });
    try obj.put("commit", .{ .string = "0x01020304" });
    const consensus_client = ClientVersionV1{ .value = .{ .object = obj } };
    const params = ClientVersionV1Params{ .consensus_client = consensus_client };

    const dummy_resp_const = try make_dummy_client_version(alloc);
    var dummy_resp = dummy_resp_const;
    defer if (dummy_resp.value == .object) dummy_resp.value.object.deinit();
    const result_value = ClientVersionV1Result{ .value = &[_]ClientVersionV1{dummy_resp_const} };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };

    var dummy = DummyEngine{ .result = exchange_result, .client_version_result = result_value };
    const api = make_api(&dummy);

    const result = try api.get_client_version_v1(params);
    try std.testing.expect(dummy.client_version_called);
    try std.testing.expectEqualDeep(result_value, result);
}

fn make_transition_config_object(
    allocator: std.mem.Allocator,
    ttd_hex: []const u8,
    hash_hex: []const u8,
    number_hex: []const u8,
) !std.json.ObjectMap {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("terminalTotalDifficulty", .{ .string = ttd_hex });
    try obj.put("terminalBlockHash", .{ .string = hash_hex });
    try obj.put("terminalBlockNumber", .{ .string = number_hex });
    return obj;
}

const zero_hash32_hex = "0x" ++ ("00" ** 32);
const zero_address20_hex = "0x" ++ ("00" ** 20);
const zero_logs_bloom256_hex = "0x" ++ ("00" ** 256);

fn make_execution_payload_v1_object(allocator: std.mem.Allocator) !struct {
    transactions: std.json.Array,
    object: std.json.ObjectMap,
} {
    var transactions = std.json.Array.init(allocator);
    errdefer transactions.deinit();
    try transactions.append(.{ .string = "0x01" });

    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();
    try obj.put("parentHash", .{ .string = zero_hash32_hex });
    try obj.put("feeRecipient", .{ .string = zero_address20_hex });
    try obj.put("stateRoot", .{ .string = zero_hash32_hex });
    try obj.put("receiptsRoot", .{ .string = zero_hash32_hex });
    try obj.put("logsBloom", .{ .string = zero_logs_bloom256_hex });
    try obj.put("prevRandao", .{ .string = zero_hash32_hex });
    try obj.put("blockNumber", .{ .string = "0x1" });
    try obj.put("gasLimit", .{ .string = "0x1" });
    try obj.put("gasUsed", .{ .string = "0x0" });
    try obj.put("timestamp", .{ .string = "0x1" });
    try obj.put("extraData", .{ .string = "0x" });
    try obj.put("baseFeePerGas", .{ .string = "0x7" });
    try obj.put("blockHash", .{ .string = zero_hash32_hex });
    try obj.put("transactions", .{ .array = transactions });

    return .{
        .transactions = transactions,
        .object = obj,
    };
}

fn make_execution_payload_v2_object(allocator: std.mem.Allocator) !struct {
    transactions: std.json.Array,
    withdrawals: std.json.Array,
    object: std.json.ObjectMap,
} {
    var payload = try make_execution_payload_v1_object(allocator);
    errdefer payload.transactions.deinit();
    errdefer payload.object.deinit();

    var withdrawals = std.json.Array.init(allocator);
    errdefer withdrawals.deinit();
    try payload.object.put("withdrawals", .{ .array = withdrawals });

    return .{
        .transactions = payload.transactions,
        .withdrawals = withdrawals,
        .object = payload.object,
    };
}

test "engine api dispatches exchangeTransitionConfigurationV1" {
    const allocator = std.testing.allocator;
    var obj = try make_transition_config_object(
        allocator,
        "0x0",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x1",
    );
    defer obj.deinit();

    const params = ExchangeTransitionConfigurationV1Params{
        .consensus_client_configuration = Quantity{ .value = .{ .object = obj } },
    };
    var ret_obj = try make_transition_config_object(
        allocator,
        "0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc00",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0",
    );
    defer ret_obj.deinit();
    const result_value = ExchangeTransitionConfigurationV1Result{
        .value = Quantity{ .value = .{ .object = ret_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .transition_result = result_value };
    const api = make_api(&dummy);

    const out = try api.exchange_transition_configuration_v1(params);
    try std.testing.expect(dummy.transition_called);
    try std.testing.expectEqualDeep(result_value, out);
}

test "engine api rejects invalid transition config params" {
    const allocator = std.testing.allocator;
    // Missing terminalBlockHash
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("terminalTotalDifficulty", .{ .string = "0x0" });
    try obj.put("terminalBlockNumber", .{ .string = "0x1" });
    defer obj.deinit();

    const params = ExchangeTransitionConfigurationV1Params{
        .consensus_client_configuration = Quantity{ .value = .{ .object = obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_transition_configuration_v1(params));
    try std.testing.expect(!dummy.transition_called);
}

test "engine api rejects transition config params with non-canonical quantity" {
    const allocator = std.testing.allocator;
    var obj = try make_transition_config_object(
        allocator,
        "0x01",
        zero_hash32_hex,
        "0x1",
    );
    defer obj.deinit();

    const params = ExchangeTransitionConfigurationV1Params{
        .consensus_client_configuration = Quantity{ .value = .{ .object = obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_transition_configuration_v1(params));
    try std.testing.expect(!dummy.transition_called);
}

test "engine api rejects transition config params with invalid hash characters" {
    const allocator = std.testing.allocator;
    var obj = try make_transition_config_object(
        allocator,
        "0x1",
        "0x" ++ ("zz" ** 32),
        "0x1",
    );
    defer obj.deinit();

    const params = ExchangeTransitionConfigurationV1Params{
        .consensus_client_configuration = Quantity{ .value = .{ .object = obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.exchange_transition_configuration_v1(params));
    try std.testing.expect(!dummy.transition_called);
}

test "engine api rejects invalid transition config response" {
    const allocator = std.testing.allocator;
    var good_obj = try make_transition_config_object(
        allocator,
        "0x1",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x2",
    );
    defer good_obj.deinit();
    const params = ExchangeTransitionConfigurationV1Params{
        .consensus_client_configuration = Quantity{ .value = .{ .object = good_obj } },
    };

    // Invalid response: terminalBlockNumber not a string hex
    var bad_obj = std.json.ObjectMap.init(allocator);
    try bad_obj.put("terminalTotalDifficulty", .{ .string = "0x1" });
    try bad_obj.put("terminalBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000000" });
    try bad_obj.put("terminalBlockNumber", .{ .float = 3.14 });
    defer bad_obj.deinit();
    const bad_result = ExchangeTransitionConfigurationV1Result{
        .value = Quantity{ .value = .{ .object = bad_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .transition_result = bad_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.exchange_transition_configuration_v1(params));
    try std.testing.expect(dummy.transition_called);
}

test "engine api generic dispatcher routes exchangeCapabilities" {
    const allocator = std.testing.allocator;

    var consensus_payload = try make_methods_payload(ConsensusType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&consensus_payload);

    var result_payload = try make_methods_payload(ResultType, allocator, &[_][]const u8{
        "engine_newPayloadV1",
    });
    defer deinit_methods_payload(&result_payload);

    const params = ExchangeCapabilitiesParams{ .consensus_client_methods = consensus_payload.value };
    const result_value = ExchangeCapabilitiesResult{ .value = result_payload.value };

    var dummy = DummyEngine{ .result = result_value };
    const api = make_api(&dummy);

    const out = try api.dispatch(ExchangeCapabilitiesMethod, params);
    try std.testing.expectEqualDeep(result_value, out);
}

// Note: generic dispatcher does not route non-Voltaire-declared methods like
// engine_getClientVersionV1. That method is invoked directly via the vtable.

test "engine api generic dispatcher routes exchangeTransitionConfigurationV1" {
    const allocator = std.testing.allocator;
    var obj = try make_transition_config_object(
        allocator,
        "0x0",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x1",
    );
    defer obj.deinit();

    const params = ExchangeTransitionConfigurationV1Params{
        .consensus_client_configuration = Quantity{ .value = .{ .object = obj } },
    };

    var ret_obj = try make_transition_config_object(
        allocator,
        "0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc00",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "0x0",
    );
    defer ret_obj.deinit();
    const result_value = ExchangeTransitionConfigurationV1Result{
        .value = Quantity{ .value = .{ .object = ret_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .transition_result = result_value };
    const api = make_api(&dummy);

    const out = try api.dispatch(ExchangeTransitionConfigurationV1Method, params);
    try std.testing.expectEqualDeep(result_value, out);
}

test "engine api dispatches newPayloadV1" {
    const alloc = std.testing.allocator;

    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const params = NewPayloadV1Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "SYNCING" });
    try status_obj.put("latestValidHash", .{ .null = {} });
    try status_obj.put("validationError", .{ .null = {} });
    const result_value = NewPayloadV1Result{
        .value = Quantity{ .value = .{ .object = status_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .new_payload_result = result_value };
    const api = make_api(&dummy);

    const out = try api.new_payload_v1(params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.new_payload_called);
}

test "engine api rejects invalid newPayloadV1 params" {
    const params = NewPayloadV1Params{
        .execution_payload = Quantity{ .value = .{ .string = "0x01" } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.new_payload_v1(params));
    try std.testing.expect(!dummy.new_payload_called);
}

test "engine api rejects newPayloadV1 params with invalid hex characters" {
    const alloc = std.testing.allocator;
    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    try payload.object.put("blockHash", .{ .string = "0x" ++ ("zz" ** 32) });

    const params = NewPayloadV1Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.new_payload_v1(params));
    try std.testing.expect(!dummy.new_payload_called);
}

test "engine api rejects newPayloadV1 params with non-canonical quantity" {
    const alloc = std.testing.allocator;
    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    try payload.object.put("blockNumber", .{ .string = "0x01" });

    const params = NewPayloadV1Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.new_payload_v1(params));
    try std.testing.expect(!dummy.new_payload_called);
}

test "engine api generic dispatcher routes newPayloadV1" {
    const alloc = std.testing.allocator;

    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const params = NewPayloadV1Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "ACCEPTED" });
    try status_obj.put("latestValidHash", .{ .null = {} });
    try status_obj.put("validationError", .{ .null = {} });
    const result_value = NewPayloadV1Result{
        .value = Quantity{ .value = .{ .object = status_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .new_payload_result = result_value };
    const api = make_api(&dummy);

    const out = try api.dispatch(NewPayloadV1Method, params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.new_payload_called);
}

test "engine api dispatches newPayloadV2" {
    const alloc = std.testing.allocator;

    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const params = NewPayloadV2Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "VALID" });
    try status_obj.put("latestValidHash", .{ .string = zero_hash32_hex });
    try status_obj.put("validationError", .{ .null = {} });
    const result_value = NewPayloadV2Result{
        .value = Quantity{ .value = .{ .object = status_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .new_payload_v2_result = result_value };
    const api = make_api(&dummy);

    const out = try api.new_payload_v2(params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.new_payload_v2_called);
}

test "engine api rejects newPayloadV2 params with post-Shanghai payload fields" {
    const alloc = std.testing.allocator;
    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    try payload.object.put("blobGasUsed", .{ .string = "0x0" });
    try payload.object.put("excessBlobGas", .{ .string = "0x0" });

    const params = NewPayloadV2Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.new_payload_v2(params));
    try std.testing.expect(!dummy.new_payload_v2_called);
}

test "engine api rejects newPayloadV2 response with INVALID_BLOCK_HASH status" {
    const alloc = std.testing.allocator;
    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const params = NewPayloadV2Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "INVALID_BLOCK_HASH" });
    try status_obj.put("latestValidHash", .{ .null = {} });
    try status_obj.put("validationError", .{ .null = {} });
    const bad_result = NewPayloadV2Result{
        .value = Quantity{ .value = .{ .object = status_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .new_payload_v2_result = bad_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.new_payload_v2(params));
    try std.testing.expect(dummy.new_payload_v2_called);
}

test "engine api generic dispatcher routes newPayloadV2" {
    const alloc = std.testing.allocator;

    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const params = NewPayloadV2Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "SYNCING" });
    try status_obj.put("latestValidHash", .{ .null = {} });
    try status_obj.put("validationError", .{ .null = {} });
    const result_value = NewPayloadV2Result{
        .value = Quantity{ .value = .{ .object = status_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .new_payload_v2_result = result_value };
    const api = make_api(&dummy);

    const out = try api.dispatch(NewPayloadV2Method, params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.new_payload_v2_called);
}

test "engine api dispatches getPayloadV1" {
    const alloc = std.testing.allocator;

    const params = GetPayloadV1Params{
        .payload_id = Quantity{ .value = .{ .string = "0x0000000000000001" } },
    };

    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();

    const result_value = GetPayloadV1Result{
        .value = Quantity{ .value = .{ .object = payload.object } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .get_payload_result = result_value };
    const api = make_api(&dummy);

    const out = try api.get_payload_v1(params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.get_payload_called);
}

test "engine api rejects invalid getPayloadV1 params" {
    const params = GetPayloadV1Params{
        .payload_id = Quantity{ .value = .{ .string = "0x01" } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.get_payload_v1(params));
    try std.testing.expect(!dummy.get_payload_called);
}

test "engine api rejects getPayloadV1 params with invalid hex characters" {
    const params = GetPayloadV1Params{
        .payload_id = Quantity{ .value = .{ .string = "0xzzzzzzzzzzzzzzzz" } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.get_payload_v1(params));
    try std.testing.expect(!dummy.get_payload_called);
}

test "engine api rejects invalid getPayloadV1 response" {
    const alloc = std.testing.allocator;

    const params = GetPayloadV1Params{
        .payload_id = Quantity{ .value = .{ .string = "0x0000000000000002" } },
    };

    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    try payload.object.put("blockHash", .{ .string = "0x1234" });

    const bad_result = GetPayloadV1Result{
        .value = Quantity{ .value = .{ .object = payload.object } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .get_payload_result = bad_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.get_payload_v1(params));
    try std.testing.expect(dummy.get_payload_called);
}

test "engine api generic dispatcher routes getPayloadV1" {
    const alloc = std.testing.allocator;

    const params = GetPayloadV1Params{
        .payload_id = Quantity{ .value = .{ .string = "0x0000000000000003" } },
    };

    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const result_value = GetPayloadV1Result{
        .value = Quantity{ .value = .{ .object = payload.object } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .get_payload_result = result_value };
    const api = make_api(&dummy);

    const out = try api.dispatch(GetPayloadV1Method, params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.get_payload_called);
}

test "engine api dispatches getPayloadV2" {
    const alloc = std.testing.allocator;

    const params = GetPayloadV2Params{
        .payload_id = Quantity{ .value = .{ .string = "0x0000000000000004" } },
    };

    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("executionPayload", .{ .object = payload.object });
    try response_obj.put("blockValue", .{ .string = "0x10" });

    const result_value = GetPayloadV2Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .get_payload_v2_result = result_value };
    const api = make_api(&dummy);

    const out = try api.get_payload_v2(params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.get_payload_v2_called);
}

test "engine api rejects invalid getPayloadV2 params" {
    const params = GetPayloadV2Params{
        .payload_id = Quantity{ .value = .{ .string = "0x01" } },
    };
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.get_payload_v2(params));
    try std.testing.expect(!dummy.get_payload_v2_called);
}

test "engine api rejects invalid getPayloadV2 response" {
    const alloc = std.testing.allocator;

    const params = GetPayloadV2Params{
        .payload_id = Quantity{ .value = .{ .string = "0x0000000000000005" } },
    };

    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    try payload.object.put("withdrawals", .{ .null = {} });

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("executionPayload", .{ .object = payload.object });
    try response_obj.put("blockValue", .{ .string = "0x10" });

    const bad_result = GetPayloadV2Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .get_payload_v2_result = bad_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.get_payload_v2(params));
    try std.testing.expect(dummy.get_payload_v2_called);
}

test "engine api generic dispatcher routes getPayloadV2" {
    const alloc = std.testing.allocator;

    const params = GetPayloadV2Params{
        .payload_id = Quantity{ .value = .{ .string = "0x0000000000000006" } },
    };

    var payload = try make_execution_payload_v2_object(alloc);
    defer payload.withdrawals.deinit();
    defer payload.transactions.deinit();
    defer payload.object.deinit();

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("executionPayload", .{ .object = payload.object });
    try response_obj.put("blockValue", .{ .string = "0x11" });

    const result_value = GetPayloadV2Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .get_payload_v2_result = result_value };
    const api = make_api(&dummy);

    const out = try api.dispatch(GetPayloadV2Method, params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.get_payload_v2_called);
}

test "engine api dispatches forkchoiceUpdatedV1" {
    const alloc = std.testing.allocator;

    var state_obj = std.json.ObjectMap.init(alloc);
    defer state_obj.deinit();
    try state_obj.put("headBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000011" });
    try state_obj.put("safeBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000010" });
    try state_obj.put("finalizedBlockHash", .{ .string = "0x000000000000000000000000000000000000000000000000000000000000000f" });

    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .object = state_obj } },
        .payload_attributes = Quantity{ .value = .{ .null = {} } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "VALID" });
    try status_obj.put("latestValidHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000011" });
    try status_obj.put("validationError", .{ .null = {} });

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("payloadStatus", .{ .object = status_obj });
    try response_obj.put("payloadId", .{ .null = {} });

    const result_value = ForkchoiceUpdatedV1Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };
    var dummy = DummyEngine{
        .result = exchange_result,
        .forkchoice_updated_result = result_value,
    };
    const api = make_api(&dummy);

    const out = try api.forkchoice_updated_v1(params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.forkchoice_updated_called);
}

test "engine api rejects invalid forkchoiceUpdatedV1 params" {
    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .string = "0x01" } },
        .payload_attributes = Quantity{ .value = .{ .null = {} } },
    };

    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.forkchoice_updated_v1(params));
    try std.testing.expect(!dummy.forkchoice_updated_called);
}

test "engine api rejects forkchoiceUpdatedV1 params with invalid hash characters" {
    const alloc = std.testing.allocator;
    var state_obj = std.json.ObjectMap.init(alloc);
    defer state_obj.deinit();
    try state_obj.put("headBlockHash", .{ .string = "0x" ++ ("zz" ** 32) });
    try state_obj.put("safeBlockHash", .{ .string = zero_hash32_hex });
    try state_obj.put("finalizedBlockHash", .{ .string = zero_hash32_hex });

    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .object = state_obj } },
        .payload_attributes = Quantity{ .value = .{ .null = {} } },
    };

    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.forkchoice_updated_v1(params));
    try std.testing.expect(!dummy.forkchoice_updated_called);
}

test "engine api rejects forkchoiceUpdatedV1 params with non-canonical payload attributes timestamp" {
    const alloc = std.testing.allocator;
    var state_obj = std.json.ObjectMap.init(alloc);
    defer state_obj.deinit();
    try state_obj.put("headBlockHash", .{ .string = zero_hash32_hex });
    try state_obj.put("safeBlockHash", .{ .string = zero_hash32_hex });
    try state_obj.put("finalizedBlockHash", .{ .string = zero_hash32_hex });

    var attrs_obj = std.json.ObjectMap.init(alloc);
    defer attrs_obj.deinit();
    try attrs_obj.put("timestamp", .{ .string = "0x01" });
    try attrs_obj.put("prevRandao", .{ .string = zero_hash32_hex });
    try attrs_obj.put("suggestedFeeRecipient", .{ .string = zero_address20_hex });

    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .object = state_obj } },
        .payload_attributes = Quantity{ .value = .{ .object = attrs_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };
    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.forkchoice_updated_v1(params));
    try std.testing.expect(!dummy.forkchoice_updated_called);
}

test "engine api rejects forkchoiceUpdatedV1 response without payloadId" {
    const alloc = std.testing.allocator;

    var state_obj = std.json.ObjectMap.init(alloc);
    defer state_obj.deinit();
    try state_obj.put("headBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000022" });
    try state_obj.put("safeBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000021" });
    try state_obj.put("finalizedBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000020" });

    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .object = state_obj } },
        .payload_attributes = Quantity{ .value = .{ .null = {} } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "VALID" });
    try status_obj.put("latestValidHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000022" });
    try status_obj.put("validationError", .{ .null = {} });

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("payloadStatus", .{ .object = status_obj });

    const result_value = ForkchoiceUpdatedV1Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .forkchoice_updated_result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.forkchoice_updated_v1(params));
    try std.testing.expect(dummy.forkchoice_updated_called);
}

test "engine api rejects forkchoiceUpdatedV1 response with non-restricted payload status" {
    const alloc = std.testing.allocator;

    var state_obj = std.json.ObjectMap.init(alloc);
    defer state_obj.deinit();
    try state_obj.put("headBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000022" });
    try state_obj.put("safeBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000021" });
    try state_obj.put("finalizedBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000020" });

    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .object = state_obj } },
        .payload_attributes = Quantity{ .value = .{ .null = {} } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "ACCEPTED" });
    try status_obj.put("latestValidHash", .{ .null = {} });
    try status_obj.put("validationError", .{ .null = {} });

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("payloadStatus", .{ .object = status_obj });
    try response_obj.put("payloadId", .{ .null = {} });

    const result_value = ForkchoiceUpdatedV1Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .forkchoice_updated_result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.forkchoice_updated_v1(params));
    try std.testing.expect(dummy.forkchoice_updated_called);
}

test "engine api rejects newPayloadV1 response with unknown payload status" {
    const alloc = std.testing.allocator;

    var payload = try make_execution_payload_v1_object(alloc);
    defer payload.transactions.deinit();
    defer payload.object.deinit();
    const params = NewPayloadV1Params{
        .execution_payload = Quantity{ .value = .{ .object = payload.object } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "PENDING" });
    try status_obj.put("latestValidHash", .{ .null = {} });
    try status_obj.put("validationError", .{ .null = {} });

    const result_value = NewPayloadV1Result{
        .value = Quantity{ .value = .{ .object = status_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };
    var dummy = DummyEngine{ .result = exchange_result, .new_payload_result = result_value };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.new_payload_v1(params));
    try std.testing.expect(dummy.new_payload_called);
}

test "engine api generic dispatcher routes forkchoiceUpdatedV1" {
    const alloc = std.testing.allocator;

    var state_obj = std.json.ObjectMap.init(alloc);
    defer state_obj.deinit();
    try state_obj.put("headBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000022" });
    try state_obj.put("safeBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000021" });
    try state_obj.put("finalizedBlockHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000020" });

    var attrs_obj = std.json.ObjectMap.init(alloc);
    defer attrs_obj.deinit();
    try attrs_obj.put("timestamp", .{ .string = "0x1" });
    try attrs_obj.put("prevRandao", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000000" });
    try attrs_obj.put("suggestedFeeRecipient", .{ .string = "0x0000000000000000000000000000000000000000" });

    const params = ForkchoiceUpdatedV1Params{
        .forkchoice_state = Quantity{ .value = .{ .object = state_obj } },
        .payload_attributes = Quantity{ .value = .{ .object = attrs_obj } },
    };

    var status_obj = std.json.ObjectMap.init(alloc);
    defer status_obj.deinit();
    try status_obj.put("status", .{ .string = "VALID" });
    try status_obj.put("latestValidHash", .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000022" });
    try status_obj.put("validationError", .{ .null = {} });

    var response_obj = std.json.ObjectMap.init(alloc);
    defer response_obj.deinit();
    try response_obj.put("payloadStatus", .{ .object = status_obj });
    try response_obj.put("payloadId", .{ .string = "0x0000000000000000" });

    const result_value = ForkchoiceUpdatedV1Result{
        .value = Quantity{ .value = .{ .object = response_obj } },
    };

    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };
    var dummy = DummyEngine{
        .result = exchange_result,
        .forkchoice_updated_result = result_value,
    };
    const api = make_api(&dummy);

    const out = try api.dispatch(ForkchoiceUpdatedV1Method, params);
    try std.testing.expectEqualDeep(result_value, out);
    try std.testing.expect(dummy.forkchoice_updated_called);
}

test "engine api generic dispatcher rejects unknown method" {
    const UnknownMethod = struct {
        params: struct {},
        result: struct {},
    };
    const params: @FieldType(UnknownMethod, "params") = .{};
    const exchange_result = ExchangeCapabilitiesResult{ .value = Quantity{ .value = .{ .null = {} } } };

    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.MethodNotFound, api.dispatch(UnknownMethod, params));
}

test "engine api rejects invalid client version params" {
    const alloc = std.testing.allocator;
    var obj = std.json.ObjectMap.init(alloc);
    defer obj.deinit();
    try obj.put("code", .{ .string = "BAD" });
    try obj.put("name", .{ .string = "Lodestar" });
    try obj.put("version", .{ .string = "v1.2.3" });
    try obj.put("commit", .{ .string = "0x01020304" });
    const consensus_client = ClientVersionV1{ .value = .{ .object = obj } };
    const bad_params = ClientVersionV1Params{ .consensus_client = consensus_client };
    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };

    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.get_client_version_v1(bad_params));
    try std.testing.expect(!dummy.client_version_called);
}

test "engine api rejects client version params with invalid commit length" {
    const alloc = std.testing.allocator;
    var obj = std.json.ObjectMap.init(alloc);
    defer obj.deinit();
    try obj.put("code", .{ .string = "LS" });
    try obj.put("name", .{ .string = "Lodestar" });
    try obj.put("version", .{ .string = "v1.2.3" });
    try obj.put("commit", .{ .string = "0x010203" });
    const consensus_client = ClientVersionV1{ .value = .{ .object = obj } };
    const bad_params = ClientVersionV1Params{ .consensus_client = consensus_client };
    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };

    var dummy = DummyEngine{ .result = exchange_result };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InvalidParams, api.get_client_version_v1(bad_params));
    try std.testing.expect(!dummy.client_version_called);
}

test "engine api rejects client version response with invalid commit format" {
    const alloc = std.testing.allocator;
    const dummy_client_version_const = try make_dummy_client_version(alloc);
    var dummy_client_version = dummy_client_version_const;
    defer if (dummy_client_version.value == .object) dummy_client_version.value.object.deinit();
    const params = ClientVersionV1Params{ .consensus_client = dummy_client_version_const };
    var bad = std.json.ObjectMap.init(alloc);
    defer bad.deinit();
    try bad.put("code", .{ .string = "LS" });
    try bad.put("name", .{ .string = "Lodestar" });
    try bad.put("version", .{ .string = "v1.2.3" });
    try bad.put("commit", .{ .string = "01020304" });
    const bad_cv = ClientVersionV1{ .value = .{ .object = bad } };
    const invalid_result = ClientVersionV1Result{ .value = &[_]ClientVersionV1{bad_cv} };
    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };

    var dummy = DummyEngine{
        .result = exchange_result,
        .client_version_result = invalid_result,
    };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.get_client_version_v1(params));
    try std.testing.expect(dummy.client_version_called);
}

test "engine api rejects invalid client version response" {
    const alloc = std.testing.allocator;
    const dummy_client_version_const = try make_dummy_client_version(alloc);
    var dummy_client_version = dummy_client_version_const;
    defer if (dummy_client_version.value == .object) dummy_client_version.value.object.deinit();
    const params = ClientVersionV1Params{ .consensus_client = dummy_client_version_const };
    const invalid_result = ClientVersionV1Result{ .value = &[_]ClientVersionV1{} };
    const exchange_result = ExchangeCapabilitiesResult{
        .value = Quantity{ .value = .{ .null = {} } },
    };

    var dummy = DummyEngine{
        .result = exchange_result,
        .client_version_result = invalid_result,
    };
    const api = make_api(&dummy);

    try std.testing.expectError(EngineApi.Error.InternalError, api.get_client_version_v1(params));
    try std.testing.expect(dummy.client_version_called);
}
