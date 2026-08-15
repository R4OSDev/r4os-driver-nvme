const r4os = @import("r4os");

const CLASS_MASS_STORAGE: u8 = 0x01;
const SUBCLASS_NVME: u8 = 0x08;

const REG_CAP: u64 = 0x00;
const REG_VS: u64 = 0x08;
const REG_CC: u64 = 0x14;
const REG_CSTS: u64 = 0x1C;
const REG_AQA: u64 = 0x24;
const REG_ASQ: u64 = 0x28;
const REG_ACQ: u64 = 0x30;

const DOORBELL_BASE: u64 = 0x1000;
const MAP_BYTES: u32 = 0x4000;
const PAGE_SIZE: u32 = 4096;

const ADMIN_QUEUE_DEPTH: u16 = 16;
const ADMIN_COMMAND_DWORDS: usize = 16;
const ADMIN_COMPLETION_BYTES: u64 = 16;
const ADMIN_WAIT_GUARD: u32 = 10_000_000;
const IO_WAIT_GUARD: u32 = 100_000_000;

const ADMIN_OP_CREATE_IO_SQ: u8 = 0x01;
const ADMIN_OP_CREATE_IO_CQ: u8 = 0x05;
const ADMIN_OP_IDENTIFY: u8 = 0x06;
const IDENTIFY_CNS_CONTROLLER: u32 = 0x01;
const IDENTIFY_CNS_ACTIVE_NAMESPACE_LIST: u32 = 0x02;
const NVM_OP_FLUSH: u8 = 0x00;
const NVM_OP_WRITE: u8 = 0x01;
const NVM_OP_READ: u8 = 0x02;
const IO_QUEUE_ID: u16 = 1;
const IO_QUEUE_DEPTH: u16 = 16;
const NVME_SECTOR_SIZE: usize = 512;
const MAX_IO_SECTORS: u16 = PAGE_SIZE / NVME_SECTOR_SIZE;
const MAX_NAMESPACES: usize = 4;

const CC_EN: u32 = 1 << 0;
const CC_CSS_NVM: u32 = 0 << 4;
const CC_MPS_SHIFT: u5 = 7;
const CC_AMS_RR: u32 = 0 << 11;
const CC_IOSQES_64: u32 = 6 << 16;
const CC_IOCQES_16: u32 = 4 << 20;
const CSTS_RDY: u32 = 1 << 0;
const CSTS_CFS: u32 = 1 << 1;

const ControllerState = struct {
    present: bool = false,
    mapped: bool = false,
    mmio_virt: u64 = 0,
    cap: u64 = 0,
    vs: u32 = 0,
    cc: u32 = 0,
    csts: u32 = 0,
    aqa: u32 = 0,
    asq: u64 = 0,
    acq: u64 = 0,
    css: u8 = 0,
    mpsmin: u8 = 0,
    doorbell_stride: u32 = 0,
    admin_queue_configured: bool = false,
    controller_ready: bool = false,
    identify_controller_ok: bool = false,
    identify_namespaces: u32 = 0,
    active_namespace_list_ok: bool = false,
    namespace_usable: bool = false,
    io_queue_configured: bool = false,
    block_device_count: usize = 0,
    queue_depth: u16 = 0,
    admin_sq_tail: u16 = 0,
    admin_cq_head: u16 = 0,
    admin_cq_phase: u8 = 1,
    io_queue_depth: u16 = 0,
    io_sq_tail: u16 = 0,
    io_cq_head: u16 = 0,
    io_cq_phase: u8 = 1,
    admin_commands: u64 = 0,
    admin_completions: u64 = 0,
    admin_failures: u64 = 0,
    admin_timeouts: u64 = 0,
    io_commands: u64 = 0,
    io_completions: u64 = 0,
    io_failures: u64 = 0,
    io_timeouts: u64 = 0,
    io_cid_mismatches: u64 = 0,
    last_admin_status: u16 = 0,
    last_io_status: u16 = 0,
    last_lba: u64 = 0,
    last_sectors: u32 = 0,
    last_error: u32 = 0,
};

const NamespaceRuntime = extern struct {
    probed: bool = false,
    identify_ok: bool = false,
    usable: bool = false,
    nsid: u32 = 0,
    lba_format: u8 = 0,
    lba_format_count: u8 = 0,
    lbads: u8 = 0,
    metadata_size: u16 = 0,
    sector_size: u32 = 0,
    sector_count: u64 = 0,
    capacity: u64 = 0,
    block_registered: bool = false,
    block_index: i32 = -1,
};

const DmaState = struct {
    asq: r4os.abi.DmaBuffer = .{},
    acq: r4os.abi.DmaBuffer = .{},
    identify: r4os.abi.DmaBuffer = .{},
    namespace: r4os.abi.DmaBuffer = .{},
    iosq: r4os.abi.DmaBuffer = .{},
    iocq: r4os.abi.DmaBuffer = .{},
    io: r4os.abi.DmaBuffer = .{},
};

var state: ControllerState = .{};
var mmio: r4os.abi.MmioRegion = .{};
var dma: DmaState = .{};
var namespaces: [MAX_NAMESPACES]NamespaceRuntime = .{NamespaceRuntime{}} ** MAX_NAMESPACES;
var backends: [MAX_NAMESPACES]r4os.abi.StorageBackend = .{r4os.abi.StorageBackend{}} ** MAX_NAMESPACES;
var next_admin_cid: u16 = 1;
var next_io_cid: u16 = 1;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("nvme_init", "nvme_shutdown"));
}

export fn nvme_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible()) {
        ctx.logError("NVME.R4D driver api mismatch");
        return -3;
    }

    resetState();
    const info = findNvme(&ctx) orelse {
        ctx.logWarn("NVME.R4D no NVMe controller found; preload boundary only");
        return 0;
    };

    state.present = true;
    if (ctx.pciEnableBusMaster(info, r4os.abi.pci_enable_memory_space) != 0) {
        ctx.logWarn("NVME.R4D bus master enable failed; legacy rescue required");
        return 0;
    }

    if (ctx.pciMapBar(info, 0, MAP_BYTES, 0, &mmio) != 0 or mmio.virt_addr == 0) {
        ctx.logWarn("NVME.R4D BAR0 map failed; legacy rescue required");
        return 0;
    }

    state.mapped = true;
    state.mmio_virt = mmio.virt_addr;
    readControllerRegisters();
    if (!initAdminPath(&ctx)) {
        ctx.logWarn("NVME.R4D admin/io init failed; legacy rescue required");
        return 0;
    }

    if (state.block_device_count == 0) {
        ctx.logWarn("NVME.R4D no namespace registered; legacy rescue required");
        return 0;
    }

    ctx.logInfo("NVME.R4D storage backend ready");
    return 0;
}

export fn nvme_shutdown() callconv(.c) i32 {
    return 0;
}

fn findNvme(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var index: u32 = 0;
    while (true) {
        var info: r4os.abi.PciDeviceInfo = .{};
        const found = ctx.pciFindByClass(CLASS_MASS_STORAGE, SUBCLASS_NVME, index, &info);
        if (found < 0) return null;
        index = @as(u32, @intCast(found)) + 1;
        return info;
    }
}

fn resetState() void {
    state = .{};
    mmio = .{};
    dma = .{};
    namespaces = .{NamespaceRuntime{}} ** MAX_NAMESPACES;
    backends = .{r4os.abi.StorageBackend{}} ** MAX_NAMESPACES;
    next_admin_cid = 1;
    next_io_cid = 1;
}

fn initAdminPath(ctx: *const r4os.r4dev.DriverContext) bool {
    if ((state.css & 0x01) == 0) return failAdmin(1);
    if (state.mpsmin != 0) return failAdmin(2);
    if (pageSizeFor(state.mpsmin) != PAGE_SIZE) return failAdmin(3);
    if (!allocateAdminBuffers(ctx)) return false;
    if (!disableController()) return false;
    configureAdminQueues();
    if (!enableController()) return false;
    if (!identifyController()) return false;
    _ = identifyNamespaces();
    if (state.namespace_usable) _ = initIoPath(ctx);
    return true;
}

fn allocateAdminBuffers(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!allocDmaPage(ctx, &dma.asq)) return failAdmin(10);
    if (!allocDmaPage(ctx, &dma.acq)) return failAdmin(11);
    if (!allocDmaPage(ctx, &dma.identify)) return failAdmin(12);
    if (!allocDmaPage(ctx, &dma.namespace)) return failAdmin(13);
    state.queue_depth = ADMIN_QUEUE_DEPTH;
    state.admin_sq_tail = 0;
    state.admin_cq_head = 0;
    state.admin_cq_phase = 1;
    return true;
}

fn allocDmaPage(ctx: *const r4os.r4dev.DriverContext, out: *r4os.abi.DmaBuffer) bool {
    if (ctx.allocDmaRegion(PAGE_SIZE, PAGE_SIZE, out) != 0) return false;
    if (out.phys_addr == 0 or out.virt_addr == 0 or out.bytes < PAGE_SIZE) return false;
    zeroPage(out.virt_addr);
    return true;
}

fn disableController() bool {
    const cc = read32(REG_CC);
    write32(REG_CC, cc & ~CC_EN);
    if (!waitReady(false)) return failAdmin(20);
    state.controller_ready = false;
    readControllerRegisters();
    return true;
}

fn configureAdminQueues() void {
    const size_zero_based = @as(u32, ADMIN_QUEUE_DEPTH - 1);
    write32(REG_AQA, size_zero_based | (size_zero_based << 16));
    write64(REG_ASQ, dma.asq.phys_addr);
    write64(REG_ACQ, dma.acq.phys_addr);
    state.aqa = read32(REG_AQA);
    state.asq = read64(REG_ASQ);
    state.acq = read64(REG_ACQ);
    state.admin_queue_configured = true;
}

fn enableController() bool {
    const mps = @as(u32, state.mpsmin) << CC_MPS_SHIFT;
    const cc = CC_EN | CC_CSS_NVM | mps | CC_AMS_RR | CC_IOSQES_64 | CC_IOCQES_16;
    write32(REG_CC, cc);
    if (!waitReady(true)) return failAdmin(21);
    state.controller_ready = true;
    readControllerRegisters();
    return true;
}

fn identifyController() bool {
    zeroPage(dma.identify.virt_addr);
    if (!submitIdentifyCommand(0, IDENTIFY_CNS_CONTROLLER, dma.identify.phys_addr)) return false;
    state.identify_controller_ok = true;
    parseIdentifyController();
    return true;
}

fn identifyNamespaces() bool {
    if (state.identify_namespaces == 0) return false;

    var nsids: [MAX_NAMESPACES]u32 = .{0} ** MAX_NAMESPACES;
    var count: usize = 0;
    if (identifyActiveNamespaceList(&nsids)) {
        state.active_namespace_list_ok = true;
        while (count < nsids.len and nsids[count] != 0) : (count += 1) {}
    } else {
        nsids[0] = 1;
        count = 1;
    }

    var ok = false;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (identifyNamespace(nsids[index], index)) ok = true;
    }
    return ok;
}

fn identifyActiveNamespaceList(out: *[MAX_NAMESPACES]u32) bool {
    zeroPage(dma.namespace.virt_addr);
    if (!submitIdentifyCommand(0, IDENTIFY_CNS_ACTIVE_NAMESPACE_LIST, dma.namespace.phys_addr)) return false;

    const words: [*]const u32 = @ptrFromInt(dma.namespace.virt_addr);
    var index: usize = 0;
    while (index < out.len) : (index += 1) {
        out[index] = words[index];
    }
    return out[0] != 0;
}

fn identifyNamespace(nsid: u32, slot: usize) bool {
    if (slot >= namespaces.len) return false;
    const ns = &namespaces[slot];
    ns.* = .{ .probed = true, .nsid = nsid };

    zeroPage(dma.namespace.virt_addr);
    if (!submitIdentifyCommand(nsid, 0, dma.namespace.phys_addr)) return false;

    ns.identify_ok = true;
    parseIdentifyNamespace(ns);
    if (ns.usable) state.namespace_usable = true;
    return ns.usable;
}

fn submitIdentifyCommand(nsid: u32, cns: u32, buffer_phys: u64) bool {
    return submitAdminCommand(ADMIN_OP_IDENTIFY, nsid, buffer_phys, cns, 0);
}

fn submitAdminCommand(opcode: u8, nsid: u32, prp1: u64, cdw10: u32, cdw11: u32) bool {
    const cid = allocateAdminCid();
    const tail = state.admin_sq_tail;
    const cmd = adminSqCommand(tail);
    @memset(cmd[0..ADMIN_COMMAND_DWORDS], 0);
    cmd[0] = @as(u32, opcode) | (@as(u32, cid) << 16);
    cmd[1] = nsid;
    cmd[6] = @truncate(prp1);
    cmd[7] = @truncate(prp1 >> 32);
    cmd[10] = cdw10;
    cmd[11] = cdw11;

    state.last_admin_status = 0xFFFF;
    state.admin_commands += 1;
    state.admin_sq_tail = nextQueueIndex(state.admin_sq_tail, state.queue_depth);
    dmaFence();
    write32(doorbellOffset(0, 0), state.admin_sq_tail);

    return pollAdminCompletion(cid);
}

fn initIoPath(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!allocateIoBuffers(ctx)) return false;
    if (!createIoCompletionQueue()) return false;
    if (!createIoSubmissionQueue()) return false;
    state.io_queue_configured = true;
    return registerNamespaceBlockDevices(ctx);
}

fn allocateIoBuffers(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!allocDmaPage(ctx, &dma.iosq)) return failIo(30);
    if (!allocDmaPage(ctx, &dma.iocq)) return failIo(31);
    if (!allocDmaPage(ctx, &dma.io)) return failIo(32);
    state.io_queue_depth = IO_QUEUE_DEPTH;
    state.io_sq_tail = 0;
    state.io_cq_head = 0;
    state.io_cq_phase = 1;
    return true;
}

fn createIoCompletionQueue() bool {
    const size_zero_based = @as(u32, state.io_queue_depth - 1);
    const cdw10 = @as(u32, IO_QUEUE_ID) | (size_zero_based << 16);
    const cdw11 = @as(u32, 1);
    return submitAdminCommand(ADMIN_OP_CREATE_IO_CQ, 0, dma.iocq.phys_addr, cdw10, cdw11);
}

fn createIoSubmissionQueue() bool {
    const size_zero_based = @as(u32, state.io_queue_depth - 1);
    const cdw10 = @as(u32, IO_QUEUE_ID) | (size_zero_based << 16);
    const cdw11 = @as(u32, 1) | (@as(u32, IO_QUEUE_ID) << 16);
    return submitAdminCommand(ADMIN_OP_CREATE_IO_SQ, 0, dma.iosq.phys_addr, cdw10, cdw11);
}

fn registerNamespaceBlockDevices(ctx: *const r4os.r4dev.DriverContext) bool {
    var ok = false;
    var index: usize = 0;
    while (index < namespaces.len) : (index += 1) {
        const ns = &namespaces[index];
        if (!ns.usable) continue;
        if (!testReadSectorZero(ns)) continue;
        if (registerBlockDevice(ctx, ns, index)) ok = true;
    }
    if (!ok) return failIo(40);
    return true;
}

fn testReadSectorZero(ns: *NamespaceRuntime) bool {
    var scratch: [NVME_SECTOR_SIZE]u8 = undefined;
    return readBlock(ns, 0, 1, scratch[0..]);
}

fn registerBlockDevice(ctx: *const r4os.r4dev.DriverContext, ns: *NamespaceRuntime, slot: usize) bool {
    if (slot >= backends.len) return false;
    const backend = &backends[slot];
    backend.* = .{
        .flags = r4os.abi.storage_backend_flag_writable,
        .source = r4os.abi.storage_backend_source_preload,
        .bus = r4os.abi.storage_backend_bus_nvme,
        .sector_size = ns.sector_size,
        .max_sectors_per_request = MAX_IO_SECTORS,
        .queue_depth = state.io_queue_depth,
        .timeout_ticks = 0,
        .sector_count = ns.sector_count,
        .context = ns,
        .read = storageRead,
        .write = storageWrite,
        .flush = storageFlush,
        .shutdown = storageShutdown,
        .status = storageStatus,
    };
    copyController(&backend.controller, "NVME.R4D");
    const block_index = ctx.registerStorageBackend(nameForNamespace(slot), backend);
    if (block_index < 0) return failIo(41);
    ns.block_registered = true;
    ns.block_index = block_index;
    state.block_device_count += 1;
    return true;
}

fn storageRead(ctx: ?*anyopaque, lba: u64, sectors: u32, out: [*]u8, len: u32) callconv(.c) i32 {
    const ns = namespaceFromContext(ctx) orelse return -1;
    if (sectors > MAX_IO_SECTORS) return -2;
    const sector_count: u16 = @intCast(sectors);
    const data = out[0..@intCast(len)];
    return if (readBlock(ns, lba, sector_count, data)) 0 else -3;
}

fn storageWrite(ctx: ?*anyopaque, lba: u64, sectors: u32, data_ptr: [*]const u8, len: u32) callconv(.c) i32 {
    const ns = namespaceFromContext(ctx) orelse return -1;
    if (sectors > MAX_IO_SECTORS) return -2;
    const sector_count: u16 = @intCast(sectors);
    const data = data_ptr[0..@intCast(len)];
    return if (writeBlock(ns, lba, sector_count, data)) 0 else -3;
}

fn storageFlush(ctx: ?*anyopaque) callconv(.c) i32 {
    const ns = namespaceFromContext(ctx) orelse return -1;
    return if (flushBlock(ns)) 0 else -2;
}

fn storageShutdown(ctx: ?*anyopaque) callconv(.c) i32 {
    _ = ctx;
    return 0;
}

fn storageStatus(ctx: ?*anyopaque, out: *r4os.abi.StorageBackendStatus) callconv(.c) i32 {
    const ns = namespaceFromContext(ctx) orelse return -1;
    out.* = .{
        .state = if (ns.usable) 1 else 0,
        .last_error = state.last_error,
        .last_lba = state.last_lba,
        .last_sectors = state.last_sectors,
        .recoveries = 0,
        .recovery_failures = state.io_failures,
    };
    return 0;
}

fn readBlock(ns: *NamespaceRuntime, lba: u64, sectors: u16, out: []u8) bool {
    const bytes = validateIoTransfer(ns, lba, sectors, out.len) orelse return false;
    const dma_bytes: [*]u8 = @ptrFromInt(dma.io.virt_addr);
    @memset(dma_bytes[0..bytes], 0);
    if (!submitIoCommand(ns.nsid, NVM_OP_READ, lba, sectors, dma.io.phys_addr)) return false;
    dmaFence();
    @memcpy(out[0..bytes], dma_bytes[0..bytes]);
    return true;
}

fn writeBlock(ns: *NamespaceRuntime, lba: u64, sectors: u16, data: []const u8) bool {
    const bytes = validateIoTransfer(ns, lba, sectors, data.len) orelse return false;
    const dma_bytes: [*]u8 = @ptrFromInt(dma.io.virt_addr);
    @memcpy(dma_bytes[0..bytes], data[0..bytes]);
    dmaFence();
    return submitIoCommand(ns.nsid, NVM_OP_WRITE, lba, sectors, dma.io.phys_addr);
}

fn flushBlock(ns: *NamespaceRuntime) bool {
    if (!state.io_queue_configured or !ns.usable) return failIo(50);
    return submitIoCommand(ns.nsid, NVM_OP_FLUSH, 0, 0, 0);
}

fn submitIoCommand(nsid: u32, opcode: u8, lba: u64, sectors: u16, prp1: u64) bool {
    const cid = allocateIoCid();
    const tail = state.io_sq_tail;
    const cmd = ioSqCommand(tail);
    @memset(cmd[0..ADMIN_COMMAND_DWORDS], 0);
    cmd[0] = @as(u32, opcode) | (@as(u32, cid) << 16);
    cmd[1] = nsid;
    if (prp1 != 0) {
        cmd[6] = @truncate(prp1);
        cmd[7] = @truncate(prp1 >> 32);
    }
    if (sectors != 0) {
        cmd[10] = @truncate(lba);
        cmd[11] = @truncate(lba >> 32);
        cmd[12] = @as(u32, sectors - 1);
    }

    state.last_io_status = 0xFFFF;
    state.last_lba = lba;
    state.last_sectors = sectors;
    state.io_commands += 1;
    state.io_sq_tail = nextQueueIndex(state.io_sq_tail, state.io_queue_depth);
    dmaFence();
    write32(doorbellOffset(IO_QUEUE_ID, 0), state.io_sq_tail);

    return pollIoCompletion(cid);
}

fn validateIoTransfer(ns: *const NamespaceRuntime, lba: u64, sectors: u16, buffer_len: usize) ?usize {
    if (!state.io_queue_configured or !ns.usable) return failIoNull(60);
    if (sectors == 0 or sectors > MAX_IO_SECTORS) return failIoNull(61);
    const bytes = @as(usize, sectors) * NVME_SECTOR_SIZE;
    if (buffer_len < bytes) return failIoNull(62);
    if (lba >= ns.sector_count) return failIoNull(63);
    if (@as(u64, sectors) > ns.sector_count - lba) return failIoNull(64);
    return bytes;
}

fn pollAdminCompletion(expected_cid: u16) bool {
    var guard: u32 = 0;
    while (guard < ADMIN_WAIT_GUARD) : (guard += 1) {
        const dw3 = adminCqDword(state.admin_cq_head, 3);
        if (completionPhase(dw3) != state.admin_cq_phase) continue;
        state.last_admin_status = completionStatus(dw3);
        state.admin_completions += 1;
        advanceAdminCqHead();

        if (completionCid(dw3) != expected_cid) return failAdmin(70);
        if (state.last_admin_status != 0) return failAdmin(71);
        return true;
    }

    state.admin_timeouts += 1;
    state.last_admin_status = completionStatus(adminCqDword(state.admin_cq_head, 3));
    return failAdmin(72);
}

fn advanceAdminCqHead() void {
    state.admin_cq_head = nextQueueIndex(state.admin_cq_head, state.queue_depth);
    if (state.admin_cq_head == 0) {
        state.admin_cq_phase = if (state.admin_cq_phase == 1) 0 else 1;
    }
    dmaFence();
    write32(doorbellOffset(0, 1), state.admin_cq_head);
}

fn pollIoCompletion(expected_cid: u16) bool {
    var guard: u32 = 0;
    while (guard < IO_WAIT_GUARD) : (guard += 1) {
        const dw3 = ioCqDword(state.io_cq_head, 3);
        if (completionPhase(dw3) != state.io_cq_phase) continue;
        state.last_io_status = completionStatus(dw3);
        state.io_completions += 1;
        advanceIoCqHead();

        if (completionCid(dw3) != expected_cid) {
            state.io_cid_mismatches += 1;
            continue;
        }
        if (state.last_io_status != 0) return failIo(80);
        return true;
    }

    state.io_timeouts += 1;
    state.last_io_status = completionStatus(ioCqDword(state.io_cq_head, 3));
    return failIo(81);
}

fn advanceIoCqHead() void {
    state.io_cq_head = nextQueueIndex(state.io_cq_head, state.io_queue_depth);
    if (state.io_cq_head == 0) {
        state.io_cq_phase = if (state.io_cq_phase == 1) 0 else 1;
    }
    dmaFence();
    write32(doorbellOffset(IO_QUEUE_ID, 1), state.io_cq_head);
}

fn readControllerRegisters() void {
    state.cap = read64(REG_CAP);
    state.vs = read32(REG_VS);
    state.cc = read32(REG_CC);
    state.csts = read32(REG_CSTS);
    state.aqa = read32(REG_AQA);
    state.asq = read64(REG_ASQ);
    state.acq = read64(REG_ACQ);

    const dstrd: u5 = @truncate((state.cap >> 32) & 0xF);
    state.doorbell_stride = @as(u32, 4) << dstrd;
    state.css = @truncate((state.cap >> 37) & 0xFF);
    state.mpsmin = @truncate((state.cap >> 48) & 0xF);
}

fn parseIdentifyController() void {
    state.identify_namespaces = identify32(516);
}

fn parseIdentifyNamespace(ns: *NamespaceRuntime) void {
    const nsze = namespace64(0);
    const ncap = namespace64(8);
    const nlbaf = namespace8(25);
    const flbas = namespace8(26);
    const format = flbas & 0x0F;
    const lbaf_offset = 128 + @as(u64, format) * 4;
    const metadata = namespace16(lbaf_offset);
    const lbads = namespace8(lbaf_offset + 2);

    ns.sector_count = nsze;
    ns.lba_format = format;
    ns.lba_format_count = nlbaf + 1;
    ns.metadata_size = metadata;
    ns.lbads = lbads;
    ns.sector_size = if (lbads < 32) @as(u32, 1) << @intCast(lbads) else 0;
    ns.capacity = 0;
    ns.usable = false;

    if (format > nlbaf) return;
    if (nsze == 0 or ncap == 0) return;
    if (ns.sector_size != 512) return;
    if (metadata != 0) return;
    if (nsze > maxU64() / ns.sector_size) return;

    ns.capacity = nsze * ns.sector_size;
    ns.usable = true;
}

fn waitReady(want_ready: bool) bool {
    var guard: u32 = 0;
    while (guard < ADMIN_WAIT_GUARD) : (guard += 1) {
        const csts = read32(REG_CSTS);
        state.csts = csts;
        if ((csts & CSTS_CFS) != 0) return false;
        const ready = (csts & CSTS_RDY) != 0;
        if (ready == want_ready) return true;
    }
    state.admin_timeouts += 1;
    return false;
}

fn failAdmin(error_code: u32) bool {
    state.admin_failures += 1;
    state.last_error = error_code;
    return false;
}

fn failIo(error_code: u32) bool {
    state.io_failures += 1;
    state.last_error = error_code;
    return false;
}

fn failIoNull(error_code: u32) ?usize {
    _ = failIo(error_code);
    return null;
}

fn namespaceFromContext(ctx: ?*anyopaque) ?*NamespaceRuntime {
    const ptr = ctx orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn nameForNamespace(slot: usize) [*:0]const u8 {
    return switch (slot) {
        0 => "nvme0",
        1 => "nvme1",
        2 => "nvme2",
        3 => "nvme3",
        else => "nvme?",
    };
}

fn copyController(out: *[32]u8, text: []const u8) void {
    @memset(out[0..], 0);
    const n = if (text.len < out.len) text.len else out.len - 1;
    if (n > 0) @memcpy(out[0..n], text[0..n]);
}

fn dmaFence() void {
    asm volatile ("mfence");
}

fn zeroPage(virt: u64) void {
    const bytes: [*]u8 = @ptrFromInt(virt);
    @memset(bytes[0..PAGE_SIZE], 0);
}

fn adminSqCommand(index_value: u16) []u32 {
    const offset = @as(u64, index_value) * 64;
    const dwords: [*]u32 = @ptrFromInt(dma.asq.virt_addr + offset);
    return dwords[0..ADMIN_COMMAND_DWORDS];
}

fn adminCqDword(index_value: u16, dword: u64) u32 {
    const offset = @as(u64, index_value) * ADMIN_COMPLETION_BYTES + dword * 4;
    const ptr: *volatile u32 = @ptrFromInt(dma.acq.virt_addr + offset);
    return ptr.*;
}

fn ioSqCommand(index_value: u16) []u32 {
    const offset = @as(u64, index_value) * 64;
    const dwords: [*]u32 = @ptrFromInt(dma.iosq.virt_addr + offset);
    return dwords[0..ADMIN_COMMAND_DWORDS];
}

fn ioCqDword(index_value: u16, dword: u64) u32 {
    const offset = @as(u64, index_value) * ADMIN_COMPLETION_BYTES + dword * 4;
    const ptr: *volatile u32 = @ptrFromInt(dma.iocq.virt_addr + offset);
    return ptr.*;
}

fn completionCid(dw3: u32) u16 {
    return @truncate(dw3 & 0xFFFF);
}

fn completionPhase(dw3: u32) u8 {
    return @truncate((dw3 >> 16) & 1);
}

fn completionStatus(dw3: u32) u16 {
    return @truncate((dw3 >> 17) & 0x7FFF);
}

fn nextQueueIndex(value: u16, depth: u16) u16 {
    const next = value + 1;
    return if (next >= depth) 0 else next;
}

fn allocateAdminCid() u16 {
    const cid = next_admin_cid;
    next_admin_cid +%= 1;
    if (next_admin_cid == 0) next_admin_cid = 1;
    return cid;
}

fn allocateIoCid() u16 {
    const cid = next_io_cid;
    next_io_cid +%= 1;
    if (next_io_cid == 0) next_io_cid = 1;
    return cid;
}

fn doorbellOffset(qid: u16, doorbell: u8) u64 {
    const index_value = @as(u64, qid) * 2 + @as(u64, doorbell);
    return DOORBELL_BASE + index_value * state.doorbell_stride;
}

fn identify8(offset: u64) u8 {
    const bytes: [*]u8 = @ptrFromInt(dma.identify.virt_addr);
    return bytes[offset];
}

fn identify16(offset: u64) u16 {
    return @as(u16, identify8(offset)) | (@as(u16, identify8(offset + 1)) << 8);
}

fn identify32(offset: u64) u32 {
    return @as(u32, identify16(offset)) | (@as(u32, identify16(offset + 2)) << 16);
}

fn namespace8(offset: u64) u8 {
    const bytes: [*]u8 = @ptrFromInt(dma.namespace.virt_addr);
    return bytes[offset];
}

fn namespace16(offset: u64) u16 {
    return @as(u16, namespace8(offset)) | (@as(u16, namespace8(offset + 1)) << 8);
}

fn namespace32(offset: u64) u32 {
    return @as(u32, namespace16(offset)) | (@as(u32, namespace16(offset + 2)) << 16);
}

fn namespace64(offset: u64) u64 {
    return @as(u64, namespace32(offset)) | (@as(u64, namespace32(offset + 4)) << 32);
}

fn maxU64() u64 {
    return ~@as(u64, 0);
}

fn read32(offset: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(state.mmio_virt + offset);
    return ptr.*;
}

fn write32(offset: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(state.mmio_virt + offset);
    ptr.* = value;
}

fn read64(offset: u64) u64 {
    const lo = read32(offset);
    const hi = read32(offset + 4);
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

fn write64(offset: u64, value: u64) void {
    write32(offset, @truncate(value));
    write32(offset + 4, @truncate(value >> 32));
}

fn pageSizeFor(mps: u8) u64 {
    const shift: u6 = @intCast(12 + @as(u16, mps));
    return @as(u64, 1) << shift;
}
