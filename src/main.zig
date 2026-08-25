const std = @import("std");
const r4os = @import("r4os");
const nvme_state = @import("nvme_state.zig");

const CLASS_MASS_STORAGE: u8 = 0x01;
const SUBCLASS_NVME: u8 = 0x08;
const PROGIF_NVME: u8 = 0x02;

const REG_CAP: u64 = 0x00;
const REG_VS: u64 = 0x08;
const REG_CC: u64 = 0x14;
const REG_CSTS: u64 = 0x1C;
const REG_AQA: u64 = 0x24;
const REG_ASQ: u64 = 0x28;
const REG_ACQ: u64 = 0x30;
const DOORBELL_BASE: u64 = 0x1000;

const PAGE_SIZE: u32 = 4096;
const INITIAL_MAP_BYTES: u32 = PAGE_SIZE;
const MAX_MMIO_BYTES: u32 = 16 * 1024 * 1024;
const MAX_CONTROLLERS: usize = 8;
const MAX_BACKENDS: usize = 8;
const MAX_NAMESPACES: usize = MAX_BACKENDS;
const MAX_IO_QUEUES: usize = 8;
const MAX_RING_ENTRIES: u16 = 16;
const MAX_QUEUE_REQUESTS: usize = 16;
const MAX_HARDWARE_IN_FLIGHT: u16 = MAX_RING_ENTRIES - 1;
const MAX_TRANSFER_BYTES: u32 = 2 * 1024 * 1024;
const ADMIN_REGION_PAGES: u32 = 4;
const IO_REGION_PAGES: u32 = 2 + MAX_QUEUE_REQUESTS;
const WORK_HANDLE_COUNT: usize = 3;

const COMMAND_DWORDS: usize = 16;
const COMPLETION_BYTES: u64 = 16;
const ADMIN_OP_DELETE_IO_SQ: u8 = 0x00;
const ADMIN_OP_CREATE_IO_SQ: u8 = 0x01;
const ADMIN_OP_DELETE_IO_CQ: u8 = 0x04;
const ADMIN_OP_CREATE_IO_CQ: u8 = 0x05;
const ADMIN_OP_IDENTIFY: u8 = 0x06;
const ADMIN_OP_ABORT: u8 = 0x08;
const ADMIN_OP_SET_FEATURES: u8 = 0x09;
const FEATURE_NUMBER_OF_QUEUES: u32 = 0x07;
const IDENTIFY_CNS_NAMESPACE: u32 = 0x00;
const IDENTIFY_CNS_CONTROLLER: u32 = 0x01;
const IDENTIFY_CNS_ACTIVE_NAMESPACE_LIST: u32 = 0x02;
const NVM_OP_FLUSH: u8 = 0x00;
const NVM_OP_WRITE: u8 = 0x01;
const NVM_OP_READ: u8 = 0x02;

const CC_EN: u32 = 1 << 0;
const CC_CSS_NVM: u32 = 0 << 4;
const CC_MPS_SHIFT: u5 = 7;
const CC_AMS_RR: u32 = 0 << 11;
const CC_IOSQES_64: u32 = 6 << 16;
const CC_IOCQES_16: u32 = 4 << 20;
const CSTS_RDY: u32 = 1 << 0;
const CSTS_CFS: u32 = 1 << 1;

const WaitOutcome = enum {
    success,
    command_failed,
    timeout,
    fatal,
    invalid,
};

const AdminResult = struct {
    outcome: WaitOutcome = .invalid,
    result: u32 = 0,
    status: u16 = 0xFFFF,
};

const ControllerPhase = enum(u8) {
    cold,
    initializing,
    ready,
    recovering,
    failed,
    stopped,
};

const SlotState = enum(u8) {
    free,
    preparing,
    pending,
    active,
    completing,
};

const NamespaceIdentity = struct {
    nsid: u32 = 0,
    active: bool = false,
    usable: bool = false,
    lba_format: u8 = 0,
    lba_format_count: u8 = 0,
    lbads: u8 = 0,
    metadata_size: u16 = 0,
    sector_size: u32 = 0,
    sector_count: u64 = 0,
    capacity: u64 = 0,
};

const IoSlot = struct {
    state: SlotState = .free,
    generation: u32 = 0,
    controller_generation: u32 = 0,
    namespace_generation: u32 = 0,
    namespace_slot: u8 = 0,
    cid: u16 = 0,
    handle: u64 = 0,
    operation: u32 = r4os.abi.storage_request_op_none,
    lba: u64 = 0,
    sectors: u16 = 0,
    bytes: u32 = 0,
    start_tick: u64 = 0,
    sequence: u64 = 0,
    cancel_reason: u32 = 0,
    prp1: u64 = 0,
    prp2: u64 = 0,
    complete: ?r4os.abi.StorageRequestComplete = null,
    pin: r4os.abi.DmaPinnedBuffer = .{},
    mapping: r4os.abi.DmaMapping = .{},
};

const IoQueue = struct {
    configured: bool = false,
    qid: u16 = 0,
    depth: u16 = 0,
    in_flight_limit: u16 = 0,
    namespace_users: u16 = 0,
    sq_head: u16 = 0,
    sq_tail: u16 = 0,
    published_tail: u16 = 0,
    cq: nvme_state.RingCursor = .{},
    active_count: u16 = 0,
    owned_count: u16 = 0,
    next_cid: u16 = 1,
    region: r4os.abi.DmaBuffer = .{},
    slots: [MAX_QUEUE_REQUESTS]IoSlot = .{IoSlot{}} ** MAX_QUEUE_REQUESTS,
    submissions: u64 = 0,
    completions: u64 = 0,
    submission_doorbells: u64 = 0,
    completion_doorbells: u64 = 0,
    cid_mismatches: u64 = 0,
};

const NamespaceRuntime = struct {
    controller_index: u8 = 0,
    slot: u8 = 0,
    generation: u32 = 1,
    identity: NamespaceIdentity = .{},
    queue_index: u8 = 0,
    max_sectors: u16 = 0,
    block_registered: bool = false,
    block_index: i32 = -1,
    name: [16:0]u8 = .{0} ** 16,
    backend: r4os.abi.StorageBackend = .{},
};

const ControllerState = struct {
    used: bool = false,
    index: u8 = 0,
    api: ?*const r4os.r4dev.DriverApi = null,
    info: r4os.abi.PciDeviceInfo = .{},
    phase: ControllerPhase = .cold,
    present: bool = false,
    mapped: bool = false,
    mmio: r4os.abi.MmioRegion = .{},
    mapped_bytes: u32 = 0,
    cap: u64 = 0,
    vs: u32 = 0,
    csts: u32 = 0,
    timer_hz: u32 = 0,
    timeout_units: u8 = 0,
    css: u8 = 0,
    mpsmin: u8 = 0,
    doorbell_stride: u32 = 0,
    mqes: u16 = 0,
    mdts: u8 = 0,
    identify_namespaces: u32 = 0,
    max_transfer_bytes: u32 = 0,
    generation: u32 = 1,
    lock: u8 = 0,
    accepting: bool = false,
    recovering: bool = false,
    shutting_down: bool = false,
    shutdown_done: bool = false,
    shutdown_safe: bool = false,
    inventory_complete: bool = true,

    admin_region: r4os.abi.DmaBuffer = .{},
    admin_depth: u16 = 0,
    admin_sq_tail: u16 = 0,
    admin_cq: nvme_state.RingCursor = .{},
    admin_pending: bool = false,
    next_admin_cid: u16 = 1,
    last_admin_result: u32 = 0,
    last_admin_status: u16 = 0,

    namespace_count: usize = 0,
    usable_namespace_count: usize = 0,
    namespaces: [MAX_NAMESPACES]NamespaceRuntime = .{NamespaceRuntime{}} ** MAX_NAMESPACES,
    requested_queue_pairs: u16 = 0,
    allocated_submission_queues: u16 = 0,
    allocated_completion_queues: u16 = 0,
    queue_pair_count: usize = 0,
    queues: [MAX_IO_QUEUES]IoQueue = .{IoQueue{}} ** MAX_IO_QUEUES,
    next_sequence: u64 = 0,

    work_pending: bool = false,
    work_handles: [WORK_HANDLE_COUNT]u32 = .{0} ** WORK_HANDLE_COUNT,
    sync_busy: bool = false,
    sync_done: bool = false,
    sync_handle: u64 = 0,
    sync_result: i32 = r4os.abi.storage_request_result_error,
    sync_bytes: u32 = 0,

    admin_commands: u64 = 0,
    admin_completions: u64 = 0,
    admin_failures: u64 = 0,
    admin_timeouts: u64 = 0,
    io_commands: u64 = 0,
    io_completions: u64 = 0,
    io_failures: u64 = 0,
    io_timeouts: u64 = 0,
    aborts: u64 = 0,
    recoveries: u64 = 0,
    recovery_failures: u64 = 0,
    last_error: u32 = 0,
    last_lba: u64 = 0,
    last_sectors: u32 = 0,
};

var driver_api: ?*const r4os.r4dev.DriverApi = null;
var controllers: [MAX_CONTROLLERS]ControllerState = .{ControllerState{}} ** MAX_CONTROLLERS;
var controller_count: usize = 0;
var registered_backends: usize = 0;
var next_sync_sequence: u64 = 1;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("nvme_init", "nvme_shutdown"));
}

export fn nvme_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible()) {
        ctx.logError("NVME.R4D driver api mismatch");
        return -3;
    }
    resetDriverState();
    driver_api = api;
    if (ctx.timerFrequency() == 0) {
        ctx.logError("NVME.R4D monotonic timer unavailable");
        return -4;
    }

    var infos: [MAX_CONTROLLERS]r4os.abi.PciDeviceInfo = .{r4os.abi.PciDeviceInfo{}} ** MAX_CONTROLLERS;
    var info_count: usize = 0;
    if (!discoverControllers(&ctx, &infos, &info_count)) {
        ctx.logError("NVME.R4D controller inventory exceeds supported platform capacity");
        return -5;
    }
    if (info_count == 0) {
        ctx.logWarn("NVME.R4D no NVMe controller found; preload boundary only");
        return 0;
    }

    controller_count = info_count;
    var ready_controllers: usize = 0;
    var inventory_complete = true;
    for (infos[0..info_count], 0..) |info, index| {
        const controller = &controllers[index];
        controller.* = .{
            .used = true,
            .index = @intCast(index),
            .api = api,
            .info = info,
            .phase = .initializing,
            .present = true,
            .timer_hz = ctx.timerFrequency(),
        };
        if (initializeController(controller, &ctx)) {
            ready_controllers += 1;
        } else {
            if (!controller.inventory_complete) inventory_complete = false;
            _ = shutdownController(controller, &ctx);
        }
    }

    if (!inventory_complete or registered_backends == 0 or ready_controllers == 0) {
        ctx.logError("NVME.R4D no complete usable namespace inventory registered");
        _ = shutdownAllControllers(&ctx);
        return -6;
    }
    ctx.logInfo("NVME.R4D parallel storage backends ready");
    return 0;
}

export fn nvme_shutdown() callconv(.c) i32 {
    const api = driver_api orelse return 0;
    var ctx = r4os.r4dev.DriverContext.init(api);
    return if (shutdownAllControllers(&ctx)) 0 else -1;
}

fn resetDriverState() void {
    controllers = .{ControllerState{}} ** MAX_CONTROLLERS;
    controller_count = 0;
    registered_backends = 0;
    next_sync_sequence = 1;
    driver_api = null;
}

fn discoverControllers(
    ctx: *const r4os.r4dev.DriverContext,
    out: *[MAX_CONTROLLERS]r4os.abi.PciDeviceInfo,
    out_count: *usize,
) bool {
    out_count.* = 0;
    var start_index: u32 = 0;
    while (true) {
        var info: r4os.abi.PciDeviceInfo = .{};
        const found = ctx.pciFindByClass(CLASS_MASS_STORAGE, SUBCLASS_NVME, start_index, &info);
        if (found < 0) return true;
        const found_index: u32 = @intCast(found);
        if (found_index == std.math.maxInt(u32)) return false;
        start_index = found_index + 1;
        if (info.prog_if != PROGIF_NVME) continue;
        if (out_count.* >= out.len) return false;
        out[out_count.*] = info;
        out_count.* += 1;
    }
}

fn initializeController(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    if (ctx.pciEnableBusMaster(controller.info, r4os.abi.pci_enable_memory_space) != 0) {
        return failController(controller, 1);
    }
    if (ctx.pciMapBar(controller.info, 0, INITIAL_MAP_BYTES, 0, &controller.mmio) != 0 or controller.mmio.virt_addr == 0) {
        return failController(controller, 2);
    }
    controller.mapped = true;
    controller.mapped_bytes = controller.mmio.bytes;
    readControllerRegisters(controller);

    if ((controller.css & 1) == 0 or controller.mpsmin != 0) return failController(controller, 3);
    const queue_contract = nvme_state.queueContract(controller.mqes, MAX_HARDWARE_IN_FLIGHT, MAX_RING_ENTRIES) orelse {
        return failController(controller, 4);
    };
    controller.admin_depth = queue_contract.ring_entries;
    if (!ensureDoorbellMapping(controller, ctx, 0)) return failController(controller, 5);
    if (!allocateAdminRegion(controller, ctx)) return failController(controller, 6);
    if (!disableController(controller)) return failController(controller, 7);
    configureAdminQueue(controller);
    if (!enableController(controller)) return failController(controller, 8);
    if (!identifyController(controller)) return failController(controller, 9);
    if (!inventoryNamespaces(controller)) {
        controller.inventory_complete = false;
        return failController(controller, 10);
    }
    if (controller.usable_namespace_count == 0) return failController(controller, 11);
    if (registered_backends + controller.usable_namespace_count > MAX_BACKENDS) {
        controller.inventory_complete = false;
        return failController(controller, 12);
    }
    if (!initializeIoQueues(controller, ctx)) return failController(controller, 13);
    assignNamespacesToQueues(controller);
    if (!registerNamespaceBackends(controller, ctx)) {
        controller.inventory_complete = false;
        return failController(controller, 14);
    }
    controller.phase = .ready;
    @atomicStore(bool, &controller.accepting, true, .release);
    return true;
}

fn allocateAdminRegion(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    const bytes = ADMIN_REGION_PAGES * PAGE_SIZE;
    if (ctx.allocDmaRegion(bytes, PAGE_SIZE, &controller.admin_region) != 0) return false;
    return controller.admin_region.phys_addr != 0 and controller.admin_region.virt_addr != 0 and
        controller.admin_region.bytes >= bytes;
}

fn disableController(controller: *ControllerState) bool {
    if (!controller.mapped) return true;
    write32(controller, REG_CC, read32(controller, REG_CC) & ~CC_EN);
    if (!waitReady(controller, false)) return false;
    controller.csts = read32(controller, REG_CSTS);
    return true;
}

fn enableController(controller: *ControllerState) bool {
    const mps = @as(u32, controller.mpsmin) << CC_MPS_SHIFT;
    write32(controller, REG_CC, CC_EN | CC_CSS_NVM | mps | CC_AMS_RR | CC_IOSQES_64 | CC_IOCQES_16);
    if (!waitReady(controller, true)) return false;
    controller.csts = read32(controller, REG_CSTS);
    return true;
}

fn configureAdminQueue(controller: *ControllerState) void {
    const size_zero_based = @as(u32, controller.admin_depth - 1);
    write32(controller, REG_AQA, size_zero_based | (size_zero_based << 16));
    write64(controller, REG_ASQ, adminSqPhys(controller));
    write64(controller, REG_ACQ, adminCqPhys(controller));
    controller.admin_sq_tail = 0;
    controller.admin_cq = .{};
    controller.admin_pending = false;
}

fn identifyController(controller: *ControllerState) bool {
    zeroBytes(identifyVirt(controller), PAGE_SIZE);
    const result = submitAdminCommand(controller, ADMIN_OP_IDENTIFY, 0, identifyPhys(controller), 0, IDENTIFY_CNS_CONTROLLER, 0);
    if (result.outcome != .success) return false;

    controller.mdts = identify8(controller, 77);
    const sqes = identify8(controller, 512);
    const cqes = identify8(controller, 513);
    const sqes_min = sqes & 0x0F;
    const sqes_max = sqes >> 4;
    const cqes_min = cqes & 0x0F;
    const cqes_max = cqes >> 4;
    if (sqes_min > 6 or sqes_max < 6 or cqes_min > 4 or cqes_max < 4) return false;
    controller.identify_namespaces = identify32(controller, 516);
    controller.max_transfer_bytes = nvme_state.mdtsBytes(controller.mdts, controller.mpsmin, MAX_TRANSFER_BYTES);
    return controller.identify_namespaces != 0 and controller.max_transfer_bytes != 0;
}

fn submitAdminCommand(
    controller: *ControllerState,
    opcode: u8,
    nsid: u32,
    prp1: u64,
    prp2: u64,
    cdw10: u32,
    cdw11: u32,
) AdminResult {
    if (controller.admin_pending or controller.admin_depth < 2) return failAdmin(controller, 20, .invalid);
    const cid = allocateAdminCid(controller);
    const tail = controller.admin_sq_tail;
    const command = adminSqCommand(controller, tail);
    @memset(command[0..COMMAND_DWORDS], 0);
    command[0] = @as(u32, opcode) | (@as(u32, cid) << 16);
    command[1] = nsid;
    command[6] = @truncate(prp1);
    command[7] = @truncate(prp1 >> 32);
    command[8] = @truncate(prp2);
    command[9] = @truncate(prp2 >> 32);
    command[10] = cdw10;
    command[11] = cdw11;
    controller.admin_pending = true;
    controller.admin_commands +%= 1;
    controller.admin_sq_tail = nvme_state.nextRingIndex(tail, controller.admin_depth) orelse return failAdmin(controller, 21, .invalid);
    dmaFence();
    write32(controller, doorbellOffset(controller, 0, false), controller.admin_sq_tail);
    return pollAdminCompletion(controller, cid);
}

fn pollAdminCompletion(controller: *ControllerState, expected_cid: u16) AdminResult {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = nvme_state.adminTimeoutTicks(controller.timer_hz);
    while (true) {
        const dw3 = adminCqDword(controller, controller.admin_cq.head, 3);
        const visible = completionPhase(dw3) == controller.admin_cq.phase;
        const csts = read32(controller, REG_CSTS);
        controller.csts = csts;
        switch (nvme_state.pollDecision(visible, (csts & CSTS_CFS) != 0, nvme_state.deadlineExpired(start, timeout, ctx.tickCount()))) {
            .completion => {
                const result_dw0 = adminCqDword(controller, controller.admin_cq.head, 0);
                const cid = completionCid(dw3);
                const status = completionStatus(dw3);
                controller.admin_completions +%= 1;
                _ = controller.admin_cq.advance(controller.admin_depth);
                dmaFence();
                write32(controller, doorbellOffset(controller, 0, true), controller.admin_cq.head);
                if (cid != expected_cid) {
                    _ = failController(controller, 22);
                    continue;
                }
                controller.admin_pending = false;
                controller.last_admin_result = result_dw0;
                controller.last_admin_status = status;
                if (status != 0) return failAdmin(controller, 23, .command_failed);
                controller.last_error = 0;
                return .{ .outcome = .success, .result = result_dw0, .status = 0 };
            },
            .fatal => return failAdmin(controller, 24, .fatal),
            .timeout => {
                controller.admin_timeouts +%= 1;
                return failAdmin(controller, 25, .timeout);
            },
            .wait => ctx.waitTicks(1),
        }
    }
}

fn failAdmin(controller: *ControllerState, code: u32, outcome: WaitOutcome) AdminResult {
    controller.admin_failures +%= 1;
    controller.last_error = code;
    return .{ .outcome = outcome, .status = controller.last_admin_status };
}

fn inventoryNamespaces(controller: *ControllerState) bool {
    var ids: [MAX_NAMESPACES]u32 = .{0} ** MAX_NAMESPACES;
    var id_count: usize = 0;
    var overflow = false;
    if (!collectActiveNamespaceIds(controller, &ids, &id_count, &overflow) or overflow) return false;

    controller.namespace_count = 0;
    controller.usable_namespace_count = 0;
    for (ids[0..id_count]) |nsid| {
        var identity = NamespaceIdentity{ .nsid = nsid };
        if (!identifyNamespace(controller, nsid, &identity)) return false;
        if (!identity.active) continue;
        if (controller.namespace_count >= controller.namespaces.len) return false;
        const slot = controller.namespace_count;
        controller.namespaces[slot] = .{
            .controller_index = controller.index,
            .slot = @intCast(slot),
            .identity = identity,
        };
        controller.namespace_count += 1;
        if (identity.usable) controller.usable_namespace_count += 1;
    }
    return controller.namespace_count != 0;
}

fn collectActiveNamespaceIds(
    controller: *ControllerState,
    out: *[MAX_NAMESPACES]u32,
    out_count: *usize,
    overflow: *bool,
) bool {
    out.* = .{0} ** MAX_NAMESPACES;
    out_count.* = 0;
    overflow.* = false;
    var cursor: u32 = 0;
    var seen: u64 = 0;
    var page_count: u32 = 0;
    while (page_count <= controller.identify_namespaces) : (page_count += 1) {
        zeroBytes(namespaceVirt(controller), PAGE_SIZE);
        const command = submitAdminCommand(
            controller,
            ADMIN_OP_IDENTIFY,
            cursor,
            namespacePhys(controller),
            0,
            IDENTIFY_CNS_ACTIVE_NAMESPACE_LIST,
            0,
        );
        if (command.outcome != .success) {
            if (command.outcome != .command_failed or cursor != 0 or controller.identify_namespaces > MAX_NAMESPACES) return false;
            var nsid: u32 = 1;
            while (nsid <= controller.identify_namespaces) : (nsid += 1) {
                if (out_count.* >= out.len) {
                    overflow.* = true;
                    return true;
                }
                out[out_count.*] = nsid;
                out_count.* += 1;
            }
            return true;
        }

        const words: [*]const u32 = @ptrFromInt(namespaceVirt(controller));
        const page = nvme_state.inspectNamespacePage(cursor, words[0 .. PAGE_SIZE / @sizeOf(u32)]);
        if (!page.valid) return false;
        var index: usize = 0;
        while (index < page.count) : (index += 1) {
            if (out_count.* < out.len) {
                out[out_count.*] = words[index];
                out_count.* += 1;
            } else {
                overflow.* = true;
            }
            seen += 1;
            if (seen > controller.identify_namespaces) return false;
        }
        if (!page.has_more) return true;
        if (page.last_nsid <= cursor) return false;
        cursor = page.last_nsid;
    }
    return false;
}

fn identifyNamespace(controller: *ControllerState, nsid: u32, out: *NamespaceIdentity) bool {
    out.* = .{ .nsid = nsid };
    zeroBytes(namespaceVirt(controller), PAGE_SIZE);
    const command = submitAdminCommand(
        controller,
        ADMIN_OP_IDENTIFY,
        nsid,
        namespacePhys(controller),
        0,
        IDENTIFY_CNS_NAMESPACE,
        0,
    );
    if (command.outcome != .success) return false;

    const nsze = namespace64(controller, 0);
    const ncap = namespace64(controller, 8);
    const nlbaf = namespace8(controller, 25);
    const format = namespace8(controller, 26) & 0x0F;
    const lbaf_offset = 128 + @as(u64, format) * 4;
    const metadata = namespace16(controller, lbaf_offset);
    const lbads = namespace8(controller, lbaf_offset + 2);
    const sector_size = if (lbads < 32) @as(u32, 1) << @intCast(lbads) else 0;

    out.* = .{
        .nsid = nsid,
        .active = nsze != 0 and ncap != 0,
        .lba_format = format,
        .lba_format_count = nlbaf + 1,
        .lbads = lbads,
        .metadata_size = metadata,
        .sector_size = sector_size,
        .sector_count = nsze,
    };
    if (!out.active or format > nlbaf or metadata != 0 or !validSectorSize(sector_size)) return true;
    if (nsze > std.math.maxInt(u64) / @as(u64, sector_size)) return true;
    out.capacity = nsze * @as(u64, sector_size);
    out.usable = true;
    return true;
}

fn initializeIoQueues(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    controller.requested_queue_pairs = @intCast(@min(controller.usable_namespace_count, MAX_IO_QUEUES));
    const requested_zero = controller.requested_queue_pairs - 1;
    const request_value = @as(u32, requested_zero) | (@as(u32, requested_zero) << 16);
    const set_features = submitAdminCommand(
        controller,
        ADMIN_OP_SET_FEATURES,
        0,
        0,
        0,
        FEATURE_NUMBER_OF_QUEUES,
        request_value,
    );
    const allocation = nvme_state.queuePairAllocation(
        controller.requested_queue_pairs,
        set_features.outcome == .success,
        set_features.result,
    );
    controller.allocated_submission_queues = allocation.allocated_submission;
    controller.allocated_completion_queues = allocation.allocated_completion;
    controller.queue_pair_count = @min(@as(usize, allocation.usable), MAX_IO_QUEUES);
    if (controller.queue_pair_count == 0 or !ensureDoorbellMapping(controller, ctx, @intCast(controller.queue_pair_count))) return false;

    const contract = nvme_state.queueContract(controller.mqes, MAX_HARDWARE_IN_FLIGHT, MAX_RING_ENTRIES) orelse return false;
    var index: usize = 0;
    while (index < controller.queue_pair_count) : (index += 1) {
        const queue = &controller.queues[index];
        queue.* = .{
            .qid = @intCast(index + 1),
            .depth = contract.ring_entries,
            .in_flight_limit = contract.in_flight,
        };
        const bytes = IO_REGION_PAGES * PAGE_SIZE;
        if (ctx.allocDmaRegion(bytes, PAGE_SIZE, &queue.region) != 0 or queue.region.phys_addr == 0 or
            queue.region.virt_addr == 0 or queue.region.bytes < bytes)
        {
            return false;
        }
        if (!createIoCompletionQueue(controller, queue) or !createIoSubmissionQueue(controller, queue)) return false;
        queue.configured = true;
    }
    return true;
}

fn createIoCompletionQueue(controller: *ControllerState, queue: *IoQueue) bool {
    const size_zero_based = @as(u32, queue.depth - 1);
    const cdw10 = @as(u32, queue.qid) | (size_zero_based << 16);
    // PC=1, IEN=0: preload happens before the platform interrupt handoff, so
    // the correct baseline is the bounded poll/deferred-work path.
    const result = submitAdminCommand(controller, ADMIN_OP_CREATE_IO_CQ, 0, ioCqPhys(queue), 0, cdw10, 1);
    return result.outcome == .success;
}

fn createIoSubmissionQueue(controller: *ControllerState, queue: *IoQueue) bool {
    const size_zero_based = @as(u32, queue.depth - 1);
    const cdw10 = @as(u32, queue.qid) | (size_zero_based << 16);
    const cdw11 = @as(u32, 1) | (@as(u32, queue.qid) << 16);
    const result = submitAdminCommand(controller, ADMIN_OP_CREATE_IO_SQ, 0, ioSqPhys(queue), 0, cdw10, cdw11);
    return result.outcome == .success;
}

fn assignNamespacesToQueues(controller: *ControllerState) void {
    var usable_index: usize = 0;
    for (controller.namespaces[0..controller.namespace_count]) |*namespace| {
        if (!namespace.identity.usable) continue;
        const queue_index = usable_index % controller.queue_pair_count;
        namespace.queue_index = @intCast(queue_index);
        controller.queues[queue_index].namespace_users += 1;
        usable_index += 1;
    }
}

fn registerNamespaceBackends(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    for (controller.namespaces[0..controller.namespace_count]) |*namespace| {
        if (!namespace.identity.usable) continue;
        const queue = &controller.queues[namespace.queue_index];
        if (queue.namespace_users == 0) return false;
        const fair_depth = @max(@as(u16, 1), queue.in_flight_limit / queue.namespace_users);
        namespace.max_sectors = nvme_state.transferSectors(controller.max_transfer_bytes, namespace.identity.sector_size);
        if (namespace.max_sectors == 0) return false;
        setNamespaceName(namespace, registered_backends);
        namespace.backend = .{
            .flags = r4os.abi.storage_backend_flag_writable,
            .source = r4os.abi.storage_backend_source_preload,
            .bus = r4os.abi.storage_backend_bus_nvme,
            .sector_size = namespace.identity.sector_size,
            .max_sectors_per_request = namespace.max_sectors,
            .queue_depth = fair_depth,
            .timeout_ticks = nvme_state.requestBudgetTicks(controller.timer_hz, controller.timeout_units),
            .sector_count = namespace.identity.sector_count,
            .context = namespace,
            .read = storageRead,
            .write = storageWrite,
            .flush = storageFlush,
            .shutdown = storageShutdown,
            .status = storageStatus,
            .submit = storageSubmit,
            .cancel = storageCancel,
            .reset = storageReset,
        };
        setControllerName(&namespace.backend.controller, controller.index);
        const block_index = ctx.registerStorageBackend(&namespace.name, &namespace.backend);
        if (block_index < 0) return false;
        namespace.block_registered = true;
        namespace.block_index = block_index;
        registered_backends += 1;
    }
    return true;
}

fn setNamespaceName(namespace: *NamespaceRuntime, index: usize) void {
    @memset(namespace.name[0..], 0);
    const prefix = "nvme";
    @memcpy(namespace.name[0..prefix.len], prefix);
    namespace.name[prefix.len] = @intCast('0' + index);
}

fn setControllerName(out: *[32]u8, index: u8) void {
    @memset(out[0..], 0);
    const prefix = "NVME";
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '0' + index;
}

fn storageRead(raw: ?*anyopaque, lba: u64, sectors: u32, out: [*]u8, len: u32) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    if (sectors == 0 or sectors > std.math.maxInt(u16)) return -2;
    return syncIo(namespace, r4os.abi.storage_request_op_read, lba, @intCast(sectors), @intFromPtr(out), len, false);
}

fn storageWrite(raw: ?*anyopaque, lba: u64, sectors: u32, data: [*]const u8, len: u32) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    if (sectors == 0 or sectors > std.math.maxInt(u16)) return -2;
    return syncIo(namespace, r4os.abi.storage_request_op_write, lba, @intCast(sectors), @intFromPtr(data), len, false);
}

fn storageFlush(raw: ?*anyopaque) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    return syncIo(namespace, r4os.abi.storage_request_op_flush, 0, 0, 0, 0, false);
}

fn storageShutdown(raw: ?*anyopaque) callconv(.c) i32 {
    _ = raw;
    const api = driver_api orelse return 0;
    var ctx = r4os.r4dev.DriverContext.init(api);
    return if (shutdownAllControllers(&ctx)) 0 else -1;
}

fn storageStatus(raw: ?*anyopaque, out: *r4os.abi.StorageBackendStatus) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    const controller = controllerForNamespace(namespace) orelse return -1;
    out.* = .{
        .state = if (namespace.identity.usable and controller.phase == .ready and
            !@atomicLoad(bool, &controller.shutting_down, .acquire)) 1 else 0,
        .last_error = controller.last_error,
        .last_lba = controller.last_lba,
        .last_sectors = controller.last_sectors,
        .recoveries = controller.recoveries,
        .recovery_failures = controller.recovery_failures,
    };
    return 0;
}

fn storageSubmit(raw: ?*anyopaque, request: *const r4os.abi.StorageRequest) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    const accepted = submitRequest(namespace, request, false);
    if (accepted != 0) return accepted;
    const controller = controllerForNamespace(namespace) orelse return -1;
    if (!scheduleControllerWork(controller)) {
        // Driver-work capacity is an acceleration facility, not an ownership
        // prerequisite. Once accepted, a request is completed inline through
        // the same CQ drain and finite recovery path rather than stranded.
        pollControllerInline(controller, request.handle);
    }
    return 0;
}

fn storageCancel(raw: ?*anyopaque, handle: u64, reason: u32) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    const controller = controllerForNamespace(namespace) orelse return -1;
    if (handle == 0 or !validCancelReason(reason) or !acquireController(controller)) return -1;

    var finish_queue: ?usize = null;
    var finish_slot: usize = 0;
    var found = false;
    for (controller.queues[0..controller.queue_pair_count], 0..) |*queue, queue_index| {
        for (&queue.slots, 0..) |*slot, slot_index| {
            if (slot.state == .free or slot.handle != handle) continue;
            found = true;
            if (slot.cancel_reason == 0) slot.cancel_reason = reason;
            if (slot.state == .pending) {
                slot.state = .completing;
                if (queue.owned_count != 0) queue.owned_count -= 1;
                finish_queue = queue_index;
                finish_slot = slot_index;
            }
            break;
        }
        if (found) break;
    }
    releaseController(controller);
    if (!found) return -1;
    if (finish_queue) |queue_index| {
        finishIoSlot(controller, queue_index, finish_slot, cancelResult(reason), 0);
        stagePendingAndPublish(controller);
    } else if (!scheduleControllerWork(controller)) {
        pollControllerInline(controller, handle);
    }
    return 0;
}

fn storageReset(raw: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const namespace = namespaceFromContext(raw) orelse return -1;
    const controller = controllerForNamespace(namespace) orelse return -1;
    return if (recoverController(controller, 0, r4os.abi.storage_request_result_reset, reason)) 0 else -1;
}

fn submitRequest(namespace: *NamespaceRuntime, request: *const r4os.abi.StorageRequest, bypass_admission: bool) i32 {
    const controller = controllerForNamespace(namespace) orelse return -1;
    if (request.version != r4os.abi.storage_request_version or request.size < @sizeOf(r4os.abi.StorageRequest) or
        request.handle == 0 or request.flags != 0)
    {
        return -1;
    }
    if (!bypass_admission and (!@atomicLoad(bool, &controller.accepting, .acquire) or
        @atomicLoad(bool, &controller.shutting_down, .acquire)))
    {
        return -2;
    }
    if (!validateTransfer(namespace, request.operation, request.lba, request.sectors, request.buffer_bytes, request.buffer_addr)) {
        return -3;
    }
    const queue_index: usize = namespace.queue_index;
    if (queue_index >= controller.queue_pair_count or !acquireController(controller)) return -4;
    const queue = &controller.queues[queue_index];
    const slot_index = reserveIoSlotLocked(controller, queue, namespace, request) orelse {
        releaseController(controller);
        return 1;
    };
    releaseController(controller);

    var prepared = true;
    if (request.operation == r4os.abi.storage_request_op_read or request.operation == r4os.abi.storage_request_op_write) {
        prepared = prepareDmaMapping(controller, queue, slot_index, request);
    }
    if (!prepared) {
        rejectPreparedSlot(controller, queue_index, slot_index);
        return -5;
    }

    if (!acquireController(controller)) {
        rejectPreparedSlot(controller, queue_index, slot_index);
        return -6;
    }
    const slot = &queue.slots[slot_index];
    if (slot.state != .preparing or slot.handle != request.handle or
        (!bypass_admission and (!controller.accepting or controller.recovering or controller.shutting_down)) or
        slot.controller_generation != controller.generation or
        slot.namespace_generation != namespace.generation)
    {
        releaseController(controller);
        rejectPreparedSlot(controller, queue_index, slot_index);
        return -7;
    }
    if (slot.cancel_reason != 0) {
        const result = cancelResult(slot.cancel_reason);
        slot.state = .completing;
        if (queue.owned_count != 0) queue.owned_count -= 1;
        releaseController(controller);
        finishIoSlot(controller, queue_index, slot_index, result, 0);
        return 0;
    }
    slot.state = .pending;
    controller.next_sequence +%= 1;
    if (controller.next_sequence == 0) controller.next_sequence = 1;
    slot.sequence = controller.next_sequence;
    stagePendingCommandsLocked(controller, queue);
    releaseController(controller);
    return 0;
}

fn reserveIoSlotLocked(
    controller: *ControllerState,
    queue: *IoQueue,
    namespace: *NamespaceRuntime,
    request: *const r4os.abi.StorageRequest,
) ?usize {
    if (!queue.configured or queue.owned_count >= queue.slots.len) return null;
    for (&queue.slots, 0..) |*slot, index| {
        if (slot.state != .free) continue;
        const generation = nextGeneration(slot.generation);
        slot.* = .{
            .state = .preparing,
            .generation = generation,
            .controller_generation = controller.generation,
            .namespace_generation = namespace.generation,
            .namespace_slot = namespace.slot,
            .handle = request.handle,
            .operation = request.operation,
            .lba = request.lba,
            .sectors = @intCast(request.sectors),
            .bytes = request.buffer_bytes,
            .complete = request.complete,
        };
        queue.owned_count += 1;
        return index;
    }
    return null;
}

fn prepareDmaMapping(
    controller: *ControllerState,
    queue: *IoQueue,
    slot_index: usize,
    request: *const r4os.abi.StorageRequest,
) bool {
    const slot = &queue.slots[slot_index];
    const ctx = controllerContext(controller);
    const bytes: usize = request.buffer_bytes;
    if (request.operation == r4os.abi.storage_request_op_read) {
        const buffer: [*]u8 = @ptrFromInt(request.buffer_addr);
        if (ctx.pinDmaBuffer(buffer[0..bytes], &slot.pin) != 0) return false;
    } else {
        const buffer: [*]const u8 = @ptrFromInt(request.buffer_addr);
        if (ctx.pinDmaConstBuffer(buffer[0..bytes], &slot.pin) != 0) return false;
    }
    const constraints = r4os.abi.DmaConstraints{
        .dma_mask = std.math.maxInt(u64),
        .boundary = 0,
        .max_segment_bytes = 0,
        .alignment = 1,
        .max_segments = r4os.abi.dma_max_segments,
        .flags = r4os.abi.dma_flag_streaming | r4os.abi.dma_flag_allow_bounce,
    };
    const direction = if (request.operation == r4os.abi.storage_request_op_read)
        r4os.abi.dma_direction_from_device
    else
        r4os.abi.dma_direction_to_device;
    if (ctx.mapDmaPinned(&slot.pin, &constraints, direction, &slot.mapping) != 0) {
        _ = ctx.unpinDmaBuffer(&slot.pin);
        return false;
    }
    if (!buildSlotPrps(queue, slot_index, slot)) {
        _ = ctx.unmapDma(&slot.mapping);
        _ = ctx.unpinDmaBuffer(&slot.pin);
        return false;
    }
    return true;
}

fn buildSlotPrps(queue: *IoQueue, slot_index: usize, slot: *IoSlot) bool {
    if (slot.mapping.segment_count == 0 or slot.mapping.segment_count > r4os.abi.dma_max_segments) return false;
    var segments: [r4os.abi.dma_max_segments]nvme_state.PhysicalSegment = undefined;
    var index: usize = 0;
    while (index < slot.mapping.segment_count) : (index += 1) {
        segments[index] = .{
            .phys_addr = slot.mapping.segments[index].phys_addr,
            .bytes = slot.mapping.segments[index].bytes,
        };
    }
    const plan = nvme_state.buildPrpPlan(segments[0..index], slot.bytes, PAGE_SIZE) catch return false;
    slot.prp1 = plan.prp1;
    slot.prp2 = plan.second_page;
    if (plan.uses_list) {
        const list: [*]u64 = @ptrFromInt(prpListVirt(queue, slot_index));
        @memset(list[0..nvme_state.max_prp_entries], 0);
        @memcpy(list[0..plan.list_count], plan.list[0..plan.list_count]);
        slot.prp2 = prpListPhys(queue, slot_index);
    }
    return true;
}

fn rejectPreparedSlot(controller: *ControllerState, queue_index: usize, slot_index: usize) void {
    if (queue_index >= controller.queue_pair_count) return;
    const queue = &controller.queues[queue_index];
    const slot = &queue.slots[slot_index];
    const ctx = controllerContext(controller);
    if (slot.mapping.handle != 0) _ = ctx.unmapDma(&slot.mapping);
    if (slot.pin.handle != 0) _ = ctx.unpinDmaBuffer(&slot.pin);
    if (!acquireController(controller)) return;
    if (slot.state == .preparing) {
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
        if (queue.owned_count != 0) queue.owned_count -= 1;
    }
    releaseController(controller);
}

fn stagePendingCommandsLocked(controller: *ControllerState, queue: *IoQueue) void {
    if (!controller.accepting and !controller.shutting_down) return;
    while (queue.active_count < queue.in_flight_limit) {
        const used = nvme_state.ringUsed(queue.sq_head, queue.sq_tail, queue.depth) orelse return;
        if (used >= queue.in_flight_limit) return;
        const slot_index = oldestPendingSlot(queue) orelse return;
        const slot = &queue.slots[slot_index];
        var active_cids: [MAX_QUEUE_REQUESTS]u16 = .{0} ** MAX_QUEUE_REQUESTS;
        var active_count: usize = 0;
        for (&queue.slots) |*active| {
            if (active.state != .active) continue;
            active_cids[active_count] = active.cid;
            active_count += 1;
        }
        const cid = nvme_state.allocateCid(&queue.next_cid, active_cids[0..active_count]) orelse return;
        const command = ioSqCommand(queue, queue.sq_tail);
        @memset(command[0..COMMAND_DWORDS], 0);
        command[0] = @as(u32, operationOpcode(slot.operation)) | (@as(u32, cid) << 16);
        command[1] = controller.namespaces[slot.namespace_slot].identity.nsid;
        command[6] = @truncate(slot.prp1);
        command[7] = @truncate(slot.prp1 >> 32);
        command[8] = @truncate(slot.prp2);
        command[9] = @truncate(slot.prp2 >> 32);
        if (slot.operation != r4os.abi.storage_request_op_flush) {
            command[10] = @truncate(slot.lba);
            command[11] = @truncate(slot.lba >> 32);
            command[12] = @as(u32, slot.sectors - 1);
        }
        slot.cid = cid;
        slot.start_tick = controllerContext(controller).tickCount();
        slot.state = .active;
        queue.sq_tail = nvme_state.nextRingIndex(queue.sq_tail, queue.depth) orelse return;
        queue.active_count += 1;
        queue.submissions +%= 1;
        controller.io_commands +%= 1;
        controller.last_lba = slot.lba;
        controller.last_sectors = slot.sectors;
    }
}

fn oldestPendingSlot(queue: *IoQueue) ?usize {
    var selected: ?usize = null;
    for (&queue.slots, 0..) |*slot, index| {
        if (slot.state != .pending) continue;
        if (selected == null or slot.sequence < queue.slots[selected.?].sequence) selected = index;
    }
    return selected;
}

fn scheduleControllerWork(controller: *ControllerState) bool {
    if (@atomicLoad(bool, &controller.shutting_down, .acquire)) return false;
    if (@atomicRmw(bool, &controller.work_pending, .Xchg, true, .acq_rel)) return true;
    const ctx = controllerContext(controller);
    releaseCompletedWork(controller, &ctx);
    var free_index: ?usize = null;
    for (&controller.work_handles, 0..) |*stored, index| {
        if (@atomicLoad(u32, stored, .acquire) == 0) {
            free_index = index;
            break;
        }
    }
    const index = free_index orelse {
        @atomicStore(bool, &controller.work_pending, false, .release);
        return false;
    };
    var handle: u32 = 0;
    if (ctx.workSubmit(controllerWork, @intFromPtr(controller), r4os.abi.driver_work_flag_none, &handle) != 0 or handle == 0) {
        @atomicStore(bool, &controller.work_pending, false, .release);
        return false;
    }
    @atomicStore(u32, &controller.work_handles[index], handle, .release);
    return true;
}

fn controllerWork(raw: usize) callconv(.c) i32 {
    const controller: *ControllerState = @ptrFromInt(raw);
    const ctx = controllerContext(controller);
    releaseCompletedWork(controller, &ctx);
    @atomicStore(bool, &controller.work_pending, false, .release);
    if (@atomicLoad(bool, &controller.shutting_down, .acquire)) return 0;

    publishSubmissionDoorbells(controller);
    drainControllerCompletions(controller);
    stagePendingAndPublish(controller);
    if (recoveryTrigger(controller)) |trigger| {
        _ = recoverController(controller, trigger.handle, trigger.result, trigger.reason);
    }
    if (controllerOwnsRequests(controller) and !@atomicLoad(bool, &controller.shutting_down, .acquire)) {
        if (!scheduleControllerWork(controller)) pollControllerInline(controller, 0);
    }
    return 0;
}

fn releaseCompletedWork(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) void {
    for (&controller.work_handles) |*stored| {
        const handle = @atomicLoad(u32, stored, .acquire);
        if (handle == 0) continue;
        var status: r4os.abi.DriverCompletionStatus = .{};
        if (ctx.completionStatus(handle, &status) != 0) continue;
        if (status.state != r4os.abi.driver_work_state_completed and status.state != r4os.abi.driver_work_state_cancelled) continue;
        if (ctx.completionRelease(handle) == 0) @atomicStore(u32, stored, 0, .release);
    }
}

fn publishSubmissionDoorbells(controller: *ControllerState) void {
    if (!acquireController(controller)) return;
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        if (!queue.configured or queue.published_tail == queue.sq_tail) continue;
        dmaFence();
        write32(controller, doorbellOffset(controller, queue.qid, false), queue.sq_tail);
        queue.published_tail = queue.sq_tail;
        queue.submission_doorbells +%= 1;
    }
    releaseController(controller);
}

fn stagePendingAndPublish(controller: *ControllerState) void {
    if (!acquireController(controller)) return;
    for (controller.queues[0..controller.queue_pair_count]) |*queue| stagePendingCommandsLocked(controller, queue);
    releaseController(controller);
    publishSubmissionDoorbells(controller);
}

const CompletionRecord = struct {
    slot_index: usize,
    result: i32,
    bytes: u32,
};

fn drainControllerCompletions(controller: *ControllerState) void {
    var queue_index: usize = 0;
    while (queue_index < controller.queue_pair_count) : (queue_index += 1) {
        drainQueueCompletions(controller, queue_index);
    }
}

fn drainQueueCompletions(controller: *ControllerState, queue_index: usize) void {
    var records: [MAX_QUEUE_REQUESTS]CompletionRecord = undefined;
    var record_count: usize = 0;
    if (!acquireController(controller)) return;
    const queue = &controller.queues[queue_index];
    if (!queue.configured) {
        releaseController(controller);
        return;
    }
    dmaFence();
    var consumed = false;
    while (record_count < records.len) {
        const dw3 = ioCqDword(queue, queue.cq.head, 3);
        if (completionPhase(dw3) != queue.cq.phase) break;
        const dw2 = ioCqDword(queue, queue.cq.head, 2);
        const cid = completionCid(dw3);
        const status = completionStatus(dw3);
        const sqid: u16 = @truncate(dw2 >> 16);
        const sq_head: u16 = @truncate(dw2);
        consumed = true;
        _ = queue.cq.advance(queue.depth);
        if (sqid == queue.qid and sq_head < queue.depth) queue.sq_head = sq_head;

        const slot_index = findActiveCid(queue, cid) orelse {
            queue.cid_mismatches +%= 1;
            continue;
        };
        const slot = &queue.slots[slot_index];
        var result: i32 = if (status == 0) r4os.abi.storage_request_result_ok else r4os.abi.storage_request_result_error;
        if (slot.cancel_reason != 0) result = cancelResult(slot.cancel_reason);
        if (slot.controller_generation != controller.generation or
            slot.namespace_slot >= controller.namespace_count or
            slot.namespace_generation != controller.namespaces[slot.namespace_slot].generation)
        {
            result = r4os.abi.storage_request_result_reset;
        }
        const bytes = if (result == r4os.abi.storage_request_result_ok and
            slot.operation != r4os.abi.storage_request_op_flush) slot.bytes else 0;
        slot.state = .completing;
        if (queue.active_count != 0) queue.active_count -= 1;
        if (queue.owned_count != 0) queue.owned_count -= 1;
        queue.completions +%= 1;
        controller.io_completions +%= 1;
        if (result != r4os.abi.storage_request_result_ok) controller.io_failures +%= 1;
        records[record_count] = .{ .slot_index = slot_index, .result = result, .bytes = bytes };
        record_count += 1;
    }
    if (consumed) {
        dmaFence();
        write32(controller, doorbellOffset(controller, queue.qid, true), queue.cq.head);
        queue.completion_doorbells +%= 1;
    }
    stagePendingCommandsLocked(controller, queue);
    releaseController(controller);

    var index: usize = 0;
    while (index < record_count) : (index += 1) {
        const record = records[index];
        finishIoSlot(controller, queue_index, record.slot_index, record.result, record.bytes);
    }
}

fn findActiveCid(queue: *IoQueue, cid: u16) ?usize {
    for (&queue.slots, 0..) |*slot, index| {
        if (slot.state == .active and slot.cid == cid) return index;
    }
    return null;
}

fn finishIoSlot(controller: *ControllerState, queue_index: usize, slot_index: usize, result: i32, bytes: u32) void {
    if (queue_index >= controller.queue_pair_count or slot_index >= MAX_QUEUE_REQUESTS) return;
    const queue = &controller.queues[queue_index];
    const slot = &queue.slots[slot_index];
    if (slot.state != .completing) return;
    const ctx = controllerContext(controller);
    if (slot.mapping.handle != 0) _ = ctx.unmapDma(&slot.mapping);
    if (slot.pin.handle != 0) _ = ctx.unpinDmaBuffer(&slot.pin);
    const complete = slot.complete;
    const handle = slot.handle;
    if (complete) |callback| callback(handle, result, bytes);

    if (!acquireController(controller)) return;
    if (slot.state == .completing and slot.handle == handle) {
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
    }
    releaseController(controller);
}

const RecoveryTrigger = struct {
    handle: u64,
    result: i32,
    reason: u32,
};

fn recoveryTrigger(controller: *ControllerState) ?RecoveryTrigger {
    if (!acquireController(controller)) return null;
    defer releaseController(controller);
    const now = controllerContext(controller).tickCount();
    const fatal = (read32(controller, REG_CSTS) & CSTS_CFS) != 0;
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        for (&queue.slots) |*slot| {
            if (slot.state != .active) continue;
            if (slot.cancel_reason != 0) {
                return .{ .handle = slot.handle, .result = cancelResult(slot.cancel_reason), .reason = slot.cancel_reason };
            }
            if (nvme_state.deadlineExpired(slot.start_tick, nvme_state.ioTimeoutTicks(controller.timer_hz), now)) {
                controller.io_timeouts +%= 1;
                return .{
                    .handle = slot.handle,
                    .result = r4os.abi.storage_request_result_timeout,
                    .reason = r4os.abi.storage_cancel_reason_timeout,
                };
            }
            if (fatal) {
                return .{ .handle = slot.handle, .result = r4os.abi.storage_request_result_error, .reason = r4os.abi.storage_cancel_reason_reset };
            }
        }
    }
    if (fatal and controllerOwnsRequestsLocked(controller)) {
        return .{ .handle = 0, .result = r4os.abi.storage_request_result_error, .reason = r4os.abi.storage_cancel_reason_reset };
    }
    return null;
}

fn pollControllerInline(controller: *ControllerState, wait_handle: u64) void {
    while (!@atomicLoad(bool, &controller.shutting_down, .acquire)) {
        publishSubmissionDoorbells(controller);
        drainControllerCompletions(controller);
        stagePendingAndPublish(controller);
        if (wait_handle != 0 and !controllerOwnsHandle(controller, wait_handle)) return;
        if (wait_handle == 0 and !controllerOwnsRequests(controller)) return;
        if (recoveryTrigger(controller)) |trigger| {
            if (!recoverController(controller, trigger.handle, trigger.result, trigger.reason)) return;
            if (wait_handle != 0 and !controllerOwnsHandle(controller, wait_handle)) return;
        }
        controllerContext(controller).waitTicks(1);
    }
}

fn controllerOwnsRequests(controller: *ControllerState) bool {
    if (!acquireController(controller)) return true;
    const owns = controllerOwnsRequestsLocked(controller);
    releaseController(controller);
    return owns;
}

fn controllerOwnsRequestsLocked(controller: *ControllerState) bool {
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        if (queue.owned_count != 0) return true;
    }
    return false;
}

fn controllerOwnsHandle(controller: *ControllerState, handle: u64) bool {
    if (!acquireController(controller)) return true;
    defer releaseController(controller);
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        for (&queue.slots) |*slot| {
            if (slot.state != .free and slot.handle == handle) return true;
        }
    }
    return false;
}

fn recoverController(controller: *ControllerState, trigger_handle: u64, trigger_result: i32, reason: u32) bool {
    if (@atomicRmw(bool, &controller.recovering, .Xchg, true, .acq_rel)) return false;
    defer @atomicStore(bool, &controller.recovering, false, .release);
    if (controller.phase == .stopped or controller.shutting_down) return false;
    controller.phase = .recovering;
    @atomicStore(bool, &controller.accepting, false, .release);
    controller.recoveries +%= 1;
    announceRecovery(controller, false, false);

    if (!waitForPreparingSlots(controller)) {
        controller.phase = .failed;
        controller.recovery_failures +%= 1;
        announceRecovery(controller, true, false);
        return false;
    }

    if (trigger_handle != 0) {
        if (activeCommandIdentity(controller, trigger_handle)) |identity| {
            const cdw10 = (@as(u32, identity.cid) << 16) | identity.qid;
            const abort = submitAdminCommand(controller, ADMIN_OP_ABORT, 0, 0, 0, cdw10, 0);
            controller.aborts +%= 1;
            if (abort.outcome == .success) {
                const ctx = controllerContext(controller);
                const start = ctx.tickCount();
                const grace = @max(@as(u64, 1), nvme_state.ticksFromMilliseconds(controller.timer_hz, 20));
                while (controllerOwnsHandle(controller, trigger_handle) and !nvme_state.deadlineExpired(start, grace, ctx.tickCount())) {
                    publishSubmissionDoorbells(controller);
                    drainControllerCompletions(controller);
                    ctx.waitTicks(1);
                }
                if (!controllerOwnsHandle(controller, trigger_handle)) {
                    controller.phase = .ready;
                    @atomicStore(bool, &controller.accepting, true, .release);
                    announceRecovery(controller, true, true);
                    stagePendingAndPublish(controller);
                    return true;
                }
            }
        }
    }

    if (!disableController(controller)) {
        controller.phase = .failed;
        controller.recovery_failures +%= 1;
        announceRecovery(controller, true, false);
        return false;
    }

    controller.generation = nextGeneration(controller.generation);
    for (controller.namespaces[0..controller.namespace_count]) |*namespace| {
        namespace.generation = nextGeneration(namespace.generation);
    }
    finishAllOwnedRequests(controller, trigger_handle, trigger_result);
    resetQueueMemoryAndSoftware(controller);
    resetAdminMemoryAndSoftware(controller);
    configureAdminQueue(controller);
    if (!enableController(controller) or !verifyNamespaceInventory(controller) or !renegotiateExistingQueues(controller)) {
        _ = disableController(controller);
        controller.phase = .failed;
        controller.recovery_failures +%= 1;
        announceRecovery(controller, true, false);
        return false;
    }
    controller.phase = .ready;
    controller.last_error = 0;
    @atomicStore(bool, &controller.accepting, true, .release);
    announceRecovery(controller, true, true);
    _ = reason;
    return true;
}

const CommandIdentity = struct {
    qid: u16,
    cid: u16,
};

fn activeCommandIdentity(controller: *ControllerState, handle: u64) ?CommandIdentity {
    if (!acquireController(controller)) return null;
    defer releaseController(controller);
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        for (&queue.slots) |*slot| {
            if (slot.state == .active and slot.handle == handle) return .{ .qid = queue.qid, .cid = slot.cid };
        }
    }
    return null;
}

fn waitForPreparingSlots(controller: *ControllerState) bool {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = nvme_state.adminTimeoutTicks(controller.timer_hz);
    while (true) {
        var preparing = false;
        if (!acquireController(controller)) return false;
        for (controller.queues[0..controller.queue_pair_count]) |*queue| {
            for (&queue.slots) |*slot| if (slot.state == .preparing) {
                preparing = true;
            };
        }
        releaseController(controller);
        if (!preparing) return true;
        if (nvme_state.deadlineExpired(start, timeout, ctx.tickCount())) return false;
        ctx.waitTicks(1);
    }
}

fn finishAllOwnedRequests(controller: *ControllerState, trigger_handle: u64, trigger_result: i32) void {
    var queue_index: usize = 0;
    while (queue_index < controller.queue_pair_count) : (queue_index += 1) {
        var slot_index: usize = 0;
        while (slot_index < MAX_QUEUE_REQUESTS) : (slot_index += 1) {
            if (!acquireController(controller)) return;
            const queue = &controller.queues[queue_index];
            const slot = &queue.slots[slot_index];
            if (slot.state == .pending or slot.state == .active) {
                const was_active = slot.state == .active;
                slot.state = .completing;
                if (was_active and queue.active_count != 0) queue.active_count -= 1;
                if (queue.owned_count != 0) queue.owned_count -= 1;
                const result = if (slot.handle == trigger_handle and trigger_handle != 0)
                    trigger_result
                else if (slot.cancel_reason != 0)
                    cancelResult(slot.cancel_reason)
                else
                    r4os.abi.storage_request_result_reset;
                releaseController(controller);
                finishIoSlot(controller, queue_index, slot_index, result, 0);
                continue;
            }
            releaseController(controller);
        }
    }
}

fn resetQueueMemoryAndSoftware(controller: *ControllerState) void {
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        if (queue.region.virt_addr != 0) zeroBytes(queue.region.virt_addr, queue.region.bytes);
        queue.configured = false;
        queue.sq_head = 0;
        queue.sq_tail = 0;
        queue.published_tail = 0;
        queue.cq = .{};
        queue.active_count = 0;
        queue.owned_count = 0;
        queue.next_cid = 1;
    }
}

fn resetAdminMemoryAndSoftware(controller: *ControllerState) void {
    if (controller.admin_region.virt_addr != 0) zeroBytes(controller.admin_region.virt_addr, controller.admin_region.bytes);
    controller.admin_sq_tail = 0;
    controller.admin_cq = .{};
    controller.admin_pending = false;
    controller.next_admin_cid = 1;
}

fn verifyNamespaceInventory(controller: *ControllerState) bool {
    var observed: [MAX_NAMESPACES]u32 = .{0} ** MAX_NAMESPACES;
    var count: usize = 0;
    var overflow = false;
    if (!collectActiveNamespaceIds(controller, &observed, &count, &overflow) or overflow or count != controller.namespace_count) return false;
    var expected: [MAX_NAMESPACES]u32 = .{0} ** MAX_NAMESPACES;
    for (controller.namespaces[0..controller.namespace_count], 0..) |*namespace, index| expected[index] = namespace.identity.nsid;
    if (!nvme_state.namespaceSetMatches(expected[0..controller.namespace_count], observed[0..count])) return false;
    for (controller.namespaces[0..controller.namespace_count]) |*namespace| {
        var identity = NamespaceIdentity{ .nsid = namespace.identity.nsid };
        if (!identifyNamespace(controller, namespace.identity.nsid, &identity)) return false;
        if (identity.active != namespace.identity.active or identity.usable != namespace.identity.usable or
            identity.sector_size != namespace.identity.sector_size or identity.sector_count != namespace.identity.sector_count or
            identity.metadata_size != namespace.identity.metadata_size or identity.lba_format != namespace.identity.lba_format)
        {
            return false;
        }
    }
    return true;
}

fn renegotiateExistingQueues(controller: *ControllerState) bool {
    const requested_zero: u16 = @intCast(controller.queue_pair_count - 1);
    const value = @as(u32, requested_zero) | (@as(u32, requested_zero) << 16);
    const set_features = submitAdminCommand(controller, ADMIN_OP_SET_FEATURES, 0, 0, 0, FEATURE_NUMBER_OF_QUEUES, value);
    const allocation = nvme_state.queuePairAllocation(@intCast(controller.queue_pair_count), set_features.outcome == .success, set_features.result);
    if (allocation.usable < controller.queue_pair_count) return false;
    for (controller.queues[0..controller.queue_pair_count]) |*queue| {
        if (!createIoCompletionQueue(controller, queue) or !createIoSubmissionQueue(controller, queue)) return false;
        queue.configured = true;
    }
    return true;
}

fn announceRecovery(controller: *ControllerState, finishing: bool, ok: bool) void {
    const ctx = controllerContext(controller);
    for (controller.namespaces[0..controller.namespace_count]) |*namespace| {
        if (!namespace.block_registered) continue;
        if (!finishing) {
            _ = ctx.storageBackendRecoveryBegin(&namespace.name);
        } else {
            _ = ctx.storageBackendRecoveryFinish(&namespace.name, ok);
        }
    }
}

fn syncIo(
    namespace: *NamespaceRuntime,
    operation: u32,
    lba: u64,
    sectors: u16,
    buffer_addr: u64,
    buffer_bytes: u32,
    bypass_admission: bool,
) i32 {
    const controller = controllerForNamespace(namespace) orelse return -1;
    if (@atomicRmw(bool, &controller.sync_busy, .Xchg, true, .acq_rel)) return -2;
    defer @atomicStore(bool, &controller.sync_busy, false, .release);
    next_sync_sequence +%= 1;
    if (next_sync_sequence == 0) next_sync_sequence = 1;
    const handle = 0xFFFE_0000_0000_0000 | next_sync_sequence;
    controller.sync_handle = handle;
    controller.sync_done = false;
    controller.sync_result = r4os.abi.storage_request_result_error;
    controller.sync_bytes = 0;
    const request = r4os.abi.StorageRequest{
        .handle = handle,
        .operation = operation,
        .lba = lba,
        .sectors = sectors,
        .buffer_bytes = buffer_bytes,
        .buffer_addr = buffer_addr,
        .complete = syncComplete,
    };
    const submitted = submitRequest(namespace, &request, bypass_admission);
    if (submitted != 0) {
        controller.sync_handle = 0;
        return submitted;
    }

    while (!@atomicLoad(bool, &controller.sync_done, .acquire)) {
        publishSubmissionDoorbells(controller);
        drainControllerCompletions(controller);
        stagePendingAndPublish(controller);
        if (recoveryTrigger(controller)) |trigger| {
            if (!recoverController(controller, trigger.handle, trigger.result, trigger.reason)) break;
        }
        if (!controllerOwnsHandle(controller, handle) and !controller.sync_done) break;
        controllerContext(controller).waitTicks(1);
    }
    controller.sync_handle = 0;
    const expected_bytes: u32 = if (operation == r4os.abi.storage_request_op_flush) 0 else buffer_bytes;
    return if (controller.sync_done and
        controller.sync_result == r4os.abi.storage_request_result_ok and
        controller.sync_bytes == expected_bytes) 0 else -3;
}

fn syncComplete(handle: u64, result: i32, bytes: u32) callconv(.c) void {
    for (controllers[0..controller_count]) |*controller| {
        if (controller.sync_handle != handle) continue;
        controller.sync_result = result;
        controller.sync_bytes = bytes;
        @atomicStore(bool, &controller.sync_done, true, .release);
        return;
    }
}

fn shutdownAllControllers(ctx: *const r4os.r4dev.DriverContext) bool {
    var safe = true;
    var index = controller_count;
    while (index != 0) {
        index -= 1;
        if (controllers[index].used and !shutdownController(&controllers[index], ctx)) safe = false;
    }
    return safe;
}

fn shutdownController(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    if (controller.shutdown_done) return controller.shutdown_safe;
    @atomicStore(bool, &controller.accepting, false, .release);
    @atomicStore(bool, &controller.shutting_down, true, .release);
    _ = waitForPreparingSlots(controller);

    var stopped = true;
    if (controller.mapped) {
        // The block owner has already stopped admissions and proved every
        // registered namespace quiescent before invoking this finalizer.  A
        // bounded flush per usable namespace and ordered SQ/CQ deletion are
        // therefore safe convenience steps.  CC.EN=0 remains the hard DMA
        // safety boundary if either step fails.
        for (controller.namespaces[0..controller.namespace_count]) |*namespace| {
            if (!namespace.identity.usable or !namespace.block_registered) continue;
            _ = syncIo(namespace, r4os.abi.storage_request_op_flush, 0, 0, 0, 0, true);
        }
        if (!controllerOwnsRequests(controller)) deleteIoQueuesBestEffort(controller);
        stopped = disableController(controller);
        if (stopped) {
            finishAllOwnedRequests(controller, 0, r4os.abi.storage_request_result_shutdown);
            resetQueueMemoryAndSoftware(controller);
            resetAdminMemoryAndSoftware(controller);
            write32(controller, REG_AQA, 0);
            write64(controller, REG_ASQ, 0);
            write64(controller, REG_ACQ, 0);
        }
    }
    const work_safe = releaseDriverWork(controller, ctx);
    const bus_master_safe = disablePciBusMaster(controller, ctx);
    const safe = stopped and work_safe and bus_master_safe;
    if (safe) {
        for (controller.queues[0..controller.queue_pair_count]) |*queue| {
            if (queue.region.phys_addr != 0) ctx.freeDmaRegion(&queue.region);
        }
        if (controller.admin_region.phys_addr != 0) ctx.freeDmaRegion(&controller.admin_region);
        controller.present = false;
        controller.phase = .stopped;
    } else {
        controller.phase = .failed;
    }
    controller.shutdown_safe = safe;
    controller.shutdown_done = safe;
    return safe;
}

fn deleteIoQueuesBestEffort(controller: *ControllerState) void {
    var index = controller.queue_pair_count;
    while (index != 0) {
        index -= 1;
        const queue = &controller.queues[index];
        if (!queue.configured) continue;
        const delete_sq = submitAdminCommand(controller, ADMIN_OP_DELETE_IO_SQ, 0, 0, 0, queue.qid, 0);
        if (delete_sq.outcome != .success) continue;
        const delete_cq = submitAdminCommand(controller, ADMIN_OP_DELETE_IO_CQ, 0, 0, 0, queue.qid, 0);
        if (delete_cq.outcome == .success) queue.configured = false;
    }
}

fn releaseDriverWork(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    @atomicStore(bool, &controller.work_pending, false, .release);
    var safe = true;
    for (&controller.work_handles) |*stored| {
        const handle = @atomicLoad(u32, stored, .acquire);
        if (handle == 0) continue;
        var status: r4os.abi.DriverCompletionStatus = .{};
        if (ctx.completionStatus(handle, &status) == 0 and status.state == r4os.abi.driver_work_state_queued) {
            _ = ctx.workCancel(handle);
        }
        var result: i32 = 0;
        const waited = ctx.completionWait(handle, nvme_state.adminTimeoutTicks(controller.timer_hz), &result);
        if (waited != 0 and waited != r4os.abi.driver_work_result_cancelled) {
            safe = false;
            continue;
        }
        if (ctx.completionRelease(handle) == 0) {
            @atomicStore(u32, stored, 0, .release);
        } else {
            safe = false;
        }
    }
    return safe;
}

fn disablePciBusMaster(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext) bool {
    if (!controller.present) return true;
    const raw = ctx.pciReadConfig32(controller.info, 0x04);
    if (raw == 0xFFFF_FFFF) return false;
    if ((raw & 0x0004) == 0) return true;
    const command = (raw & 0x0000_FFFF) & ~@as(u32, 0x0004);
    if (ctx.pciWriteConfig32(controller.info, 0x04, command) != 0) return false;
    const verified = ctx.pciReadConfig32(controller.info, 0x04);
    return verified != 0xFFFF_FFFF and (verified & 0x0004) == 0;
}

fn validateTransfer(namespace: *const NamespaceRuntime, operation: u32, lba: u64, sectors: u32, bytes: u32, buffer_addr: u64) bool {
    if (!namespace.identity.usable) return false;
    switch (operation) {
        r4os.abi.storage_request_op_flush => return sectors == 0 and bytes == 0 and buffer_addr == 0,
        r4os.abi.storage_request_op_read, r4os.abi.storage_request_op_write => {},
        else => return false,
    }
    if (sectors == 0 or sectors > namespace.max_sectors or sectors > std.math.maxInt(u16) or buffer_addr == 0) return false;
    const expected = std.math.mul(u64, sectors, namespace.identity.sector_size) catch return false;
    if (expected != bytes or expected > MAX_TRANSFER_BYTES) return false;
    if (lba >= namespace.identity.sector_count or sectors > namespace.identity.sector_count - lba) return false;
    return true;
}

fn operationOpcode(operation: u32) u8 {
    return switch (operation) {
        r4os.abi.storage_request_op_read => NVM_OP_READ,
        r4os.abi.storage_request_op_write => NVM_OP_WRITE,
        r4os.abi.storage_request_op_flush => NVM_OP_FLUSH,
        else => 0xFF,
    };
}

fn validCancelReason(reason: u32) bool {
    return reason == r4os.abi.storage_cancel_reason_timeout or
        reason == r4os.abi.storage_cancel_reason_caller or
        reason == r4os.abi.storage_cancel_reason_reset or
        reason == r4os.abi.storage_cancel_reason_shutdown;
}

fn cancelResult(reason: u32) i32 {
    return switch (reason) {
        r4os.abi.storage_cancel_reason_timeout => r4os.abi.storage_request_result_timeout,
        r4os.abi.storage_cancel_reason_reset => r4os.abi.storage_request_result_reset,
        r4os.abi.storage_cancel_reason_shutdown => r4os.abi.storage_request_result_shutdown,
        else => r4os.abi.storage_request_result_cancelled,
    };
}

fn namespaceFromContext(raw: ?*anyopaque) ?*NamespaceRuntime {
    const ptr = raw orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn controllerForNamespace(namespace: *const NamespaceRuntime) ?*ControllerState {
    if (namespace.controller_index >= controller_count) return null;
    const controller = &controllers[namespace.controller_index];
    if (!controller.used or namespace.slot >= controller.namespace_count or
        &controller.namespaces[namespace.slot] != namespace)
    {
        return null;
    }
    return controller;
}

fn controllerContext(controller: *const ControllerState) r4os.r4dev.DriverContext {
    return r4os.r4dev.DriverContext.init(controller.api.?);
}

fn acquireController(controller: *ControllerState) bool {
    var attempts: u32 = 0;
    while (attempts < 64) : (attempts += 1) {
        if (@cmpxchgWeak(u8, &controller.lock, 0, 1, .acquire, .monotonic) == null) return true;
        controllerContext(controller).waitTicks(1);
    }
    return false;
}

fn releaseController(controller: *ControllerState) void {
    @atomicStore(u8, &controller.lock, 0, .release);
}

fn nextGeneration(previous: u32) u32 {
    const next = previous +% 1;
    return if (next == 0) 1 else next;
}

fn allocateAdminCid(controller: *ControllerState) u16 {
    var cid = controller.next_admin_cid;
    if (cid == 0) cid = 1;
    controller.next_admin_cid = cid +% 1;
    if (controller.next_admin_cid == 0) controller.next_admin_cid = 1;
    return cid;
}

fn validSectorSize(size: u32) bool {
    return size == 512 or size == 1024 or size == 2048 or size == 4096;
}

fn failController(controller: *ControllerState, code: u32) bool {
    controller.last_error = code;
    controller.phase = .failed;
    return false;
}

fn waitReady(controller: *ControllerState, want_ready: bool) bool {
    const ctx = controllerContext(controller);
    const start = ctx.tickCount();
    const timeout = nvme_state.controllerTimeoutTicks(controller.timer_hz, controller.timeout_units);
    while (true) {
        const csts = read32(controller, REG_CSTS);
        controller.csts = csts;
        const ready = (csts & CSTS_RDY) != 0;
        if (ready == want_ready) return true;
        if (want_ready and (csts & CSTS_CFS) != 0) return false;
        if (nvme_state.deadlineExpired(start, timeout, ctx.tickCount())) {
            controller.admin_timeouts +%= 1;
            return false;
        }
        ctx.waitTicks(1);
    }
}

fn ensureDoorbellMapping(controller: *ControllerState, ctx: *const r4os.r4dev.DriverContext, highest_qid: u16) bool {
    const required = requiredMmioBytes(controller, highest_qid) orelse return false;
    if (controller.mapped_bytes >= required) return true;
    var expanded: r4os.abi.MmioRegion = .{};
    if (ctx.pciMapBar(controller.info, 0, required, 0, &expanded) != 0 or expanded.virt_addr == 0) return false;
    controller.mmio = expanded;
    controller.mapped_bytes = expanded.bytes;
    return true;
}

fn requiredMmioBytes(controller: *const ControllerState, highest_qid: u16) ?u32 {
    const doorbell_index = @as(u64, highest_qid) * 2 + 1;
    const end = std.math.add(u64, DOORBELL_BASE, doorbell_index * controller.doorbell_stride + 4) catch return null;
    const aligned = (end + PAGE_SIZE - 1) & ~(@as(u64, PAGE_SIZE) - 1);
    if (aligned > MAX_MMIO_BYTES) return null;
    return @intCast(aligned);
}

fn readControllerRegisters(controller: *ControllerState) void {
    controller.cap = read64(controller, REG_CAP);
    controller.vs = read32(controller, REG_VS);
    controller.csts = read32(controller, REG_CSTS);
    controller.mqes = @truncate(controller.cap & 0xFFFF);
    controller.timeout_units = @truncate((controller.cap >> 24) & 0xFF);
    const dstrd: u5 = @truncate((controller.cap >> 32) & 0x0F);
    controller.doorbell_stride = @as(u32, 4) << dstrd;
    controller.css = @truncate((controller.cap >> 37) & 0xFF);
    controller.mpsmin = @truncate((controller.cap >> 48) & 0x0F);
}

fn adminSqPhys(controller: *const ControllerState) u64 {
    return controller.admin_region.phys_addr;
}

fn adminCqPhys(controller: *const ControllerState) u64 {
    return controller.admin_region.phys_addr + PAGE_SIZE;
}

fn identifyPhys(controller: *const ControllerState) u64 {
    return controller.admin_region.phys_addr + 2 * PAGE_SIZE;
}

fn namespacePhys(controller: *const ControllerState) u64 {
    return controller.admin_region.phys_addr + 3 * PAGE_SIZE;
}

fn adminSqVirt(controller: *const ControllerState) u64 {
    return controller.admin_region.virt_addr;
}

fn adminCqVirt(controller: *const ControllerState) u64 {
    return controller.admin_region.virt_addr + PAGE_SIZE;
}

fn identifyVirt(controller: *const ControllerState) u64 {
    return controller.admin_region.virt_addr + 2 * PAGE_SIZE;
}

fn namespaceVirt(controller: *const ControllerState) u64 {
    return controller.admin_region.virt_addr + 3 * PAGE_SIZE;
}

fn ioSqPhys(queue: *const IoQueue) u64 {
    return queue.region.phys_addr;
}

fn ioCqPhys(queue: *const IoQueue) u64 {
    return queue.region.phys_addr + PAGE_SIZE;
}

fn ioSqVirt(queue: *const IoQueue) u64 {
    return queue.region.virt_addr;
}

fn ioCqVirt(queue: *const IoQueue) u64 {
    return queue.region.virt_addr + PAGE_SIZE;
}

fn prpListPhys(queue: *const IoQueue, slot_index: usize) u64 {
    return queue.region.phys_addr + @as(u64, @intCast(2 + slot_index)) * PAGE_SIZE;
}

fn prpListVirt(queue: *const IoQueue, slot_index: usize) u64 {
    return queue.region.virt_addr + @as(u64, @intCast(2 + slot_index)) * PAGE_SIZE;
}

fn adminSqCommand(controller: *const ControllerState, index: u16) []u32 {
    const dwords: [*]u32 = @ptrFromInt(adminSqVirt(controller) + @as(u64, index) * 64);
    return dwords[0..COMMAND_DWORDS];
}

fn adminCqDword(controller: *const ControllerState, index: u16, dword: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(adminCqVirt(controller) + @as(u64, index) * COMPLETION_BYTES + dword * 4);
    return ptr.*;
}

fn ioSqCommand(queue: *const IoQueue, index: u16) []u32 {
    const dwords: [*]u32 = @ptrFromInt(ioSqVirt(queue) + @as(u64, index) * 64);
    return dwords[0..COMMAND_DWORDS];
}

fn ioCqDword(queue: *const IoQueue, index: u16, dword: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(ioCqVirt(queue) + @as(u64, index) * COMPLETION_BYTES + dword * 4);
    return ptr.*;
}

fn completionCid(dw3: u32) u16 {
    return @truncate(dw3);
}

fn completionPhase(dw3: u32) u8 {
    return @truncate((dw3 >> 16) & 1);
}

fn completionStatus(dw3: u32) u16 {
    return @truncate((dw3 >> 17) & 0x7FFF);
}

fn doorbellOffset(controller: *const ControllerState, qid: u16, completion: bool) u64 {
    const index = @as(u64, qid) * 2 + @intFromBool(completion);
    return DOORBELL_BASE + index * controller.doorbell_stride;
}

fn identify8(controller: *const ControllerState, offset: u64) u8 {
    const bytes: [*]const u8 = @ptrFromInt(identifyVirt(controller));
    return bytes[offset];
}

fn identify16(controller: *const ControllerState, offset: u64) u16 {
    return @as(u16, identify8(controller, offset)) | (@as(u16, identify8(controller, offset + 1)) << 8);
}

fn identify32(controller: *const ControllerState, offset: u64) u32 {
    return @as(u32, identify16(controller, offset)) | (@as(u32, identify16(controller, offset + 2)) << 16);
}

fn namespace8(controller: *const ControllerState, offset: u64) u8 {
    const bytes: [*]const u8 = @ptrFromInt(namespaceVirt(controller));
    return bytes[offset];
}

fn namespace16(controller: *const ControllerState, offset: u64) u16 {
    return @as(u16, namespace8(controller, offset)) | (@as(u16, namespace8(controller, offset + 1)) << 8);
}

fn namespace32(controller: *const ControllerState, offset: u64) u32 {
    return @as(u32, namespace16(controller, offset)) | (@as(u32, namespace16(controller, offset + 2)) << 16);
}

fn namespace64(controller: *const ControllerState, offset: u64) u64 {
    return @as(u64, namespace32(controller, offset)) | (@as(u64, namespace32(controller, offset + 4)) << 32);
}

fn zeroBytes(virt_addr: u64, bytes: u32) void {
    if (virt_addr == 0 or bytes == 0) return;
    const target: [*]u8 = @ptrFromInt(virt_addr);
    @memset(target[0..bytes], 0);
}

fn dmaFence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn read32(controller: *const ControllerState, offset: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(controller.mmio.virt_addr + offset);
    return ptr.*;
}

fn write32(controller: *const ControllerState, offset: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(controller.mmio.virt_addr + offset);
    ptr.* = value;
}

fn read64(controller: *const ControllerState, offset: u64) u64 {
    const lo = read32(controller, offset);
    const hi = read32(controller, offset + 4);
    return (@as(u64, hi) << 32) | lo;
}

fn write64(controller: *const ControllerState, offset: u64, value: u64) void {
    write32(controller, offset, @truncate(value));
    write32(controller, offset + 4, @truncate(value >> 32));
}
