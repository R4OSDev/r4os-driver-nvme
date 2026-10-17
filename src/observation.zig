//! Optional per-request evidence. Normal requests retain the original prefix.
const r4os = @import("r4os");
const abi = r4os.abi;
pub const Bound = struct { cookie: u64 = 0, callback: ?abi.StorageRequestObserve = null };
pub const Path = struct { flags: u32 = 0, irq_generation: u64 = 0, work_sequence: u64 = 0 };
pub fn bind(request: *const abi.StorageRequest) ?Bound {
    if (request.flags == 0) return .{};
    if (request.flags != abi.storage_request_flag_observation or request.size < @sizeOf(abi.StorageObservedRequest)) return null;
    const observed: *const abi.StorageObservedRequest = @ptrCast(@alignCast(request));
    if (observed.observation_version != abi.storage_observation_version or observed.reserved0 != 0 or observed.cookie == 0 or observed.observe == null) return null;
    return .{ .cookie = observed.cookie, .callback = observed.observe };
}
