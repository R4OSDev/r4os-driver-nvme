const std = @import("std");

pub const max_prp_entries: usize = 512;

pub const PollDecision = enum {
    completion,
    fatal,
    timeout,
    wait,
};

pub const RuntimeWorkDecision = enum {
    stop,
    resubmit_event,
    resubmit_poll_fallback,
};

/// CDW11 for Create I/O Completion Queue: PC is always set because each CQ
/// owns one contiguous DMA page range. IEN and IV are coupled; callers may
/// create an interrupt-capable queue while keeping its PCI message route
/// disabled until the asynchronous runtime begins.
pub fn ioCompletionQueueControl(interrupts_enabled: bool, vector: u16) u32 {
    return 1 |
        (if (interrupts_enabled) @as(u32, 1 << 1) else 0) |
        (if (interrupts_enabled) @as(u32, vector) << 16 else 0);
}

/// Event-driven runtime queues stop after one finite pass. A raced IRQ owns a
/// bounded successor; only controllers without a usable MSI route retain the
/// old polling continuation as an explicit fallback.
pub fn runtimeWorkDecision(
    interrupts_armed: bool,
    generation_changed: bool,
    owns_requests: bool,
    shutting_down: bool,
) RuntimeWorkDecision {
    if (shutting_down) return .stop;
    if (generation_changed) return .resubmit_event;
    if (owns_requests and !interrupts_armed) return .resubmit_poll_fallback;
    return .stop;
}

pub fn runtimeInterruptAllowed(
    registered: bool,
    armed: bool,
    accepting: bool,
    recovering: bool,
    shutting_down: bool,
) bool {
    return registered and armed and accepting and !recovering and !shutting_down;
}

pub const QueueContract = struct {
    ring_entries: u16,
    in_flight: u16,
    depth_one_fallback: bool,
};

/// NVMe reports MQES as a zero-based maximum. One entry is retained as the
/// host-side full/empty discriminator, so a hardware ring of two entries is
/// the smallest usable depth-one command path.
pub fn queueContract(mqes_zero_based: u16, requested_in_flight: u16, hard_ring_cap: u16) ?QueueContract {
    if (requested_in_flight == 0 or hard_ring_cap < 2) return null;
    const controller_entries_u32 = @as(u32, mqes_zero_based) + 1;
    const requested_entries_u32 = @as(u32, requested_in_flight) + 1;
    const ring_entries_u32 = @min(controller_entries_u32, @min(requested_entries_u32, hard_ring_cap));
    if (ring_entries_u32 < 2) return null;
    const in_flight: u16 = @intCast(ring_entries_u32 - 1);
    return .{
        .ring_entries = @intCast(ring_entries_u32),
        .in_flight = in_flight,
        .depth_one_fallback = in_flight == 1,
    };
}

pub const QueuePairAllocation = struct {
    requested: u16,
    allocated_submission: u16,
    allocated_completion: u16,
    usable: u16,
    negotiated: bool,
};

/// Set Features / Number of Queues returns zero-based SQ/CQ allocations in
/// DW0. A rejected feature command retains one standards-compatible pair.
pub fn queuePairAllocation(requested: u16, command_succeeded: bool, result_dw0: u32) QueuePairAllocation {
    const wanted = @max(@as(u16, 1), requested);
    if (!command_succeeded) {
        return .{
            .requested = wanted,
            .allocated_submission = 1,
            .allocated_completion = 1,
            .usable = 1,
            .negotiated = false,
        };
    }
    const submission_u32 = @as(u32, @as(u16, @truncate(result_dw0))) + 1;
    const completion_u32 = @as(u32, @as(u16, @truncate(result_dw0 >> 16))) + 1;
    const submission: u16 = @intCast(@min(submission_u32, std.math.maxInt(u16)));
    const completion: u16 = @intCast(@min(completion_u32, std.math.maxInt(u16)));
    return .{
        .requested = wanted,
        .allocated_submission = submission,
        .allocated_completion = completion,
        .usable = @max(@as(u16, 1), @min(wanted, @min(submission, completion))),
        .negotiated = true,
    };
}

pub const NamespacePage = struct {
    count: usize = 0,
    last_nsid: u32 = 0,
    has_more: bool = false,
    valid: bool = true,
};

/// Active Namespace List pages are strictly increasing and are continued by
/// placing the final NSID from a full page in the next Identify command.
pub fn inspectNamespacePage(cursor: u32, entries: []const u32) NamespacePage {
    if (entries.len == 0) return .{ .valid = false };
    var result = NamespacePage{};
    var previous = cursor;
    for (entries) |nsid| {
        if (nsid == 0) break;
        if (nsid <= previous) return .{ .valid = false };
        previous = nsid;
        result.last_nsid = nsid;
        result.count += 1;
    }
    result.has_more = result.count == entries.len and result.last_nsid != 0;
    return result;
}

pub const PhysicalSegment = struct {
    phys_addr: u64,
    bytes: u32,
};

pub const PrpPlan = struct {
    prp1: u64 = 0,
    second_page: u64 = 0,
    list_count: u16 = 0,
    uses_list: bool = false,
    list: [max_prp_entries]u64 = .{0} ** max_prp_entries,
};

pub const PrpError = error{
    InvalidArgument,
    IncompleteMapping,
    MisalignedPage,
    TooManyPages,
    Overflow,
};

/// Convert a logically contiguous DMA segment stream into NVMe PRP1/PRP2
/// form. Transfers needing more than one trailing page use exactly one
/// caller-owned PRP-list page; chained list pages remain deliberately out of
/// scope, which keeps the maximum transfer finite and auditable.
pub fn buildPrpPlan(segments: []const PhysicalSegment, bytes: u32, page_size: u32) PrpError!PrpPlan {
    if (segments.len == 0 or bytes == 0 or page_size == 0 or !std.math.isPowerOfTwo(page_size)) {
        return error.InvalidArgument;
    }
    var total: u64 = 0;
    for (segments) |segment| {
        if (segment.phys_addr == 0 or segment.bytes == 0) return error.InvalidArgument;
        total = std.math.add(u64, total, segment.bytes) catch return error.Overflow;
    }
    if (total < bytes) return error.IncompleteMapping;

    var plan = PrpPlan{};
    plan.prp1 = physicalAt(segments, 0) orelse return error.IncompleteMapping;
    const page_mask = @as(u64, page_size) - 1;
    const first_capacity: u64 = @as(u64, page_size) - (plan.prp1 & page_mask);
    if (bytes <= first_capacity) return plan;

    var logical_offset = first_capacity;
    var remaining = @as(u64, bytes) - first_capacity;
    const second = physicalAt(segments, logical_offset) orelse return error.IncompleteMapping;
    if ((second & page_mask) != 0) return error.MisalignedPage;
    plan.second_page = second;
    if (remaining <= page_size) return plan;

    plan.uses_list = true;
    while (remaining != 0) {
        if (plan.list_count >= max_prp_entries) return error.TooManyPages;
        const phys_addr = physicalAt(segments, logical_offset) orelse return error.IncompleteMapping;
        if ((phys_addr & page_mask) != 0) return error.MisalignedPage;
        plan.list[plan.list_count] = phys_addr;
        plan.list_count += 1;
        const take = @min(remaining, @as(u64, page_size));
        remaining -= take;
        logical_offset += take;
    }
    return plan;
}

fn physicalAt(segments: []const PhysicalSegment, logical_offset: u64) ?u64 {
    var base: u64 = 0;
    for (segments) |segment| {
        const end = std.math.add(u64, base, segment.bytes) catch return null;
        if (logical_offset < end) {
            return std.math.add(u64, segment.phys_addr, logical_offset - base) catch null;
        }
        base = end;
    }
    return null;
}

pub const RingCursor = struct {
    head: u16 = 0,
    phase: u8 = 1,

    pub fn advance(self: *RingCursor, depth: u16) bool {
        if (depth < 2 or self.head >= depth) return false;
        self.head += 1;
        if (self.head == depth) {
            self.head = 0;
            self.phase ^= 1;
        }
        return true;
    }
};

pub fn nextRingIndex(value: u16, depth: u16) ?u16 {
    if (depth < 2 or value >= depth) return null;
    const next = value + 1;
    return if (next == depth) 0 else next;
}

pub fn ringUsed(head: u16, tail: u16, depth: u16) ?u16 {
    if (depth < 2 or head >= depth or tail >= depth) return null;
    return if (tail >= head) tail - head else depth - head + tail;
}

pub fn allocateCid(next_candidate: *u16, active: []const u16) ?u16 {
    var attempts: u32 = 0;
    while (attempts < std.math.maxInt(u16)) : (attempts += 1) {
        var candidate = next_candidate.*;
        if (candidate == 0) candidate = 1;
        next_candidate.* = candidate +% 1;
        if (next_candidate.* == 0) next_candidate.* = 1;
        var occupied = false;
        for (active) |cid| {
            if (cid == candidate) {
                occupied = true;
                break;
            }
        }
        if (!occupied) return candidate;
    }
    return null;
}

pub fn namespaceSetMatches(expected: []const u32, observed: []const u32) bool {
    if (expected.len != observed.len) return false;
    for (expected, observed) |left, right| if (left != right) return false;
    return true;
}

pub fn mdtsBytes(mdts: u8, mpsmin: u8, hard_limit: u32) u32 {
    if (hard_limit == 0) return 0;
    if (mdts == 0) return hard_limit;
    const shift: u16 = 12 + @as(u16, mpsmin) + @as(u16, mdts);
    if (shift >= 32) return hard_limit;
    return @min(hard_limit, @as(u32, 1) << @intCast(shift));
}

pub fn transferSectors(byte_limit: u32, sector_size: u32) u16 {
    if (byte_limit == 0 or sector_size == 0) return 0;
    return @intCast(@min(@as(u64, byte_limit / sector_size), std.math.maxInt(u16)));
}

/// A synchronous read is safe to issue once more only when its first attempt
/// forced a transport recovery that completed successfully.  Command-status,
/// validation and DMA-preparation failures do not advance the recovery
/// generation and therefore remain terminal for the caller.
pub fn replayRecoveredRead(recoveries_before: u64, recoveries_after: u64, controller_ready: bool) bool {
    return controller_ready and recoveries_after > recoveries_before;
}

/// Preserve a failed NVM completion in the compact public backend status.
/// 0x8OOOPSSS means: I/O completion, 12-bit PRP1 page offset OOO, PRP2
/// present flag P, and the controller's unmodified 15-bit status SSS.
pub fn ioCompletionError(status: u16, prp1: u64, has_prp2: bool) u32 {
    if (status == 0) return 0;
    const prp_offset: u32 = @intCast(prp1 & 0xFFF);
    return 0x8000_0000 |
        (prp_offset << 16) |
        (if (has_prp2) @as(u32, 1 << 15) else 0) |
        @as(u32, status & 0x7FFF);
}

pub fn deadlineExpired(start_tick: u64, timeout_ticks: u64, now: u64) bool {
    return timeout_ticks != 0 and now -% start_tick >= timeout_ticks;
}

/// Completion wins when it is already visible in the queue. Otherwise fatal
/// controller state terminates the wait before the monotone deadline does.
pub fn pollDecision(completion_visible: bool, fatal: bool, expired: bool) PollDecision {
    if (completion_visible) return .completion;
    if (fatal) return .fatal;
    if (expired) return .timeout;
    return .wait;
}

pub fn ticksFromMilliseconds(timer_hz: u32, milliseconds: u64) u64 {
    if (timer_hz == 0 or milliseconds == 0) return 0;
    const numerator = @as(u128, timer_hz) * @as(u128, milliseconds) + 999;
    const ticks = numerator / 1000;
    return @intCast(@min(ticks, @as(u128, std.math.maxInt(u64))));
}

/// CAP.TO is expressed directly in 500 ms units (FFh == 127.5 s). A zero
/// value receives one timer tick of observation tolerance.
pub fn controllerTimeoutTicks(timer_hz: u32, timeout_units: u8) u64 {
    return @max(@as(u64, 1), ticksFromMilliseconds(timer_hz, @as(u64, timeout_units) * 500));
}

pub fn adminTimeoutTicks(timer_hz: u32) u64 {
    return @max(@as(u64, 1), ticksFromMilliseconds(timer_hz, 5_000));
}

pub fn ioTimeoutTicks(timer_hz: u32) u64 {
    return @max(@as(u64, 1), ticksFromMilliseconds(timer_hz, 5_000));
}

pub fn requestBudgetTicks(timer_hz: u32, timeout_units: u8) u64 {
    const admin = adminTimeoutTicks(timer_hz);
    const io = ioTimeoutTicks(timer_hz);
    const transition = controllerTimeoutTicks(timer_hz, timeout_units);
    var total: u64 = 1;
    total +|= io *| 2;
    total +|= admin *| 5;
    total +|= transition *| 4;
    return total;
}

test "MQES clamps rings and preserves a real depth-one fallback" {
    const normal = queueContract(63, 15, 16) orelse return error.MissingContract;
    try std.testing.expectEqual(@as(u16, 16), normal.ring_entries);
    try std.testing.expectEqual(@as(u16, 15), normal.in_flight);
    try std.testing.expect(!normal.depth_one_fallback);

    const fallback = queueContract(1, 15, 16) orelse return error.MissingFallback;
    try std.testing.expectEqual(@as(u16, 2), fallback.ring_entries);
    try std.testing.expectEqual(@as(u16, 1), fallback.in_flight);
    try std.testing.expect(fallback.depth_one_fallback);
    try std.testing.expect(queueContract(0, 1, 16) == null);
}

test "queue-pair negotiation honors both returned dimensions and fallback" {
    const allocated = queuePairAllocation(4, true, (@as(u32, 2) << 16) | 3);
    try std.testing.expectEqual(@as(u16, 4), allocated.allocated_submission);
    try std.testing.expectEqual(@as(u16, 3), allocated.allocated_completion);
    try std.testing.expectEqual(@as(u16, 3), allocated.usable);
    try std.testing.expect(allocated.negotiated);

    const fallback = queuePairAllocation(8, false, 0);
    try std.testing.expectEqual(@as(u16, 1), fallback.usable);
    try std.testing.expect(!fallback.negotiated);
}

test "I/O completion queues couple IEN to a valid vector choice" {
    try std.testing.expectEqual(@as(u32, 0x0000_0001), ioCompletionQueueControl(false, 7));
    try std.testing.expectEqual(@as(u32, 0x0000_0003), ioCompletionQueueControl(true, 0));
    try std.testing.expectEqual(@as(u32, 0x0007_0003), ioCompletionQueueControl(true, 7));
}

test "runtime work is event-driven with only an explicit polling fallback" {
    try std.testing.expectEqual(
        RuntimeWorkDecision.stop,
        runtimeWorkDecision(true, false, true, false),
    );
    try std.testing.expectEqual(
        RuntimeWorkDecision.resubmit_event,
        runtimeWorkDecision(true, true, true, false),
    );
    try std.testing.expectEqual(
        RuntimeWorkDecision.resubmit_poll_fallback,
        runtimeWorkDecision(false, false, true, false),
    );
    try std.testing.expectEqual(
        RuntimeWorkDecision.stop,
        runtimeWorkDecision(false, true, true, true),
    );
}

test "interrupt lifecycle keeps preload recovery and shutdown masked" {
    try std.testing.expect(!runtimeInterruptAllowed(true, false, true, false, false));
    try std.testing.expect(!runtimeInterruptAllowed(false, true, true, false, false));
    try std.testing.expect(runtimeInterruptAllowed(true, true, true, false, false));
    try std.testing.expect(!runtimeInterruptAllowed(true, true, false, false, false));
    try std.testing.expect(!runtimeInterruptAllowed(true, true, true, true, false));
    try std.testing.expect(!runtimeInterruptAllowed(true, true, true, false, true));
}

test "namespace pages continue without repeating or losing the boundary NSID" {
    const first = [_]u32{ 2, 4, 9 };
    const first_page = inspectNamespacePage(0, &first);
    try std.testing.expect(first_page.valid);
    try std.testing.expect(first_page.has_more);
    try std.testing.expectEqual(@as(u32, 9), first_page.last_nsid);

    const last = [_]u32{ 12, 20, 0 };
    const last_page = inspectNamespacePage(first_page.last_nsid, &last);
    try std.testing.expect(last_page.valid);
    try std.testing.expect(!last_page.has_more);
    try std.testing.expectEqual(@as(usize, 2), last_page.count);
    try std.testing.expect(!inspectNamespacePage(9, &[_]u32{ 9, 10, 0 }).valid);
}

test "PRP planning covers one page, PRP2 and a non-contiguous list" {
    const one = [_]PhysicalSegment{.{ .phys_addr = 0x1080, .bytes = 512 }};
    const one_plan = try buildPrpPlan(&one, 512, 4096);
    try std.testing.expectEqual(@as(u64, 0x1080), one_plan.prp1);
    try std.testing.expectEqual(@as(u64, 0), one_plan.second_page);

    const two = [_]PhysicalSegment{
        .{ .phys_addr = 0x1800, .bytes = 2048 },
        .{ .phys_addr = 0x9000, .bytes = 4096 },
    };
    const two_plan = try buildPrpPlan(&two, 4096, 4096);
    try std.testing.expectEqual(@as(u64, 0x9000), two_plan.second_page);
    try std.testing.expect(!two_plan.uses_list);

    const many = [_]PhysicalSegment{
        .{ .phys_addr = 0x1800, .bytes = 2048 },
        .{ .phys_addr = 0x9000, .bytes = 4096 },
        .{ .phys_addr = 0xD000, .bytes = 4096 },
    };
    const many_plan = try buildPrpPlan(&many, 10 * 1024, 4096);
    try std.testing.expect(many_plan.uses_list);
    try std.testing.expectEqual(@as(u16, 2), many_plan.list_count);
    try std.testing.expectEqual(@as(u64, 0x9000), many_plan.list[0]);
    try std.testing.expectEqual(@as(u64, 0xD000), many_plan.list[1]);
}

test "PRP planning rejects a segment boundary that breaks page identity" {
    const bad = [_]PhysicalSegment{
        .{ .phys_addr = 0x1800, .bytes = 2048 },
        .{ .phys_addr = 0x9100, .bytes = 4096 },
    };
    try std.testing.expectError(error.MisalignedPage, buildPrpPlan(&bad, 4096, 4096));
}

test "queue wrap flips phase and occupancy remains bounded" {
    var cursor = RingCursor{ .head = 2, .phase = 1 };
    try std.testing.expect(cursor.advance(3));
    try std.testing.expectEqual(@as(u16, 0), cursor.head);
    try std.testing.expectEqual(@as(u8, 0), cursor.phase);
    try std.testing.expectEqual(@as(u16, 2), ringUsed(3, 1, 4).?);
    try std.testing.expectEqual(@as(u16, 0), nextRingIndex(3, 4).?);
}

test "CID allocation skips active identities across wrap" {
    var next: u16 = std.math.maxInt(u16);
    const first = allocateCid(&next, &[_]u16{1}) orelse return error.NoCid;
    try std.testing.expectEqual(std.math.maxInt(u16), first);
    const second = allocateCid(&next, &[_]u16{ 1, 2 }) orelse return error.NoCid;
    try std.testing.expectEqual(@as(u16, 3), second);
}

test "namespace generation comparison rejects removal reorder and replacement" {
    try std.testing.expect(namespaceSetMatches(&[_]u32{ 1, 3, 7 }, &[_]u32{ 1, 3, 7 }));
    try std.testing.expect(!namespaceSetMatches(&[_]u32{ 1, 3, 7 }, &[_]u32{ 1, 7 }));
    try std.testing.expect(!namespaceSetMatches(&[_]u32{ 1, 3, 7 }, &[_]u32{ 1, 4, 7 }));
}

test "MDTS and sector size bound larger transfers" {
    try std.testing.expectEqual(@as(u32, 2 * 1024 * 1024), mdtsBytes(0, 0, 2 * 1024 * 1024));
    try std.testing.expectEqual(@as(u32, 32 * 1024), mdtsBytes(3, 0, 2 * 1024 * 1024));
    try std.testing.expectEqual(@as(u16, 64), transferSectors(32 * 1024, 512));
    try std.testing.expectEqual(@as(u16, 8), transferSectors(32 * 1024, 4096));
}

test "boot read replay requires a completed transport recovery" {
    try std.testing.expect(replayRecoveredRead(3, 4, true));
    try std.testing.expect(!replayRecoveredRead(3, 3, true));
    try std.testing.expect(!replayRecoveredRead(3, 4, false));
}

test "I/O completion diagnostics retain status PRP offset and PRP2 presence" {
    try std.testing.expectEqual(@as(u32, 0), ioCompletionError(0, 0x123, true));
    try std.testing.expectEqual(@as(u32, 0x8123_8004), ioCompletionError(4, 0xABC0_0123, true));
    try std.testing.expectEqual(@as(u32, 0x8FFF_7FFF), ioCompletionError(0xFFFF, 0xFFFF, false));
}

test "timeouts remain monotone across tick wrap and visible completion wins" {
    const start = std.math.maxInt(u64) - 2;
    try std.testing.expect(!deadlineExpired(start, 4, 0));
    try std.testing.expect(deadlineExpired(start, 4, 1));
    try std.testing.expectEqual(PollDecision.wait, pollDecision(false, false, false));
    try std.testing.expectEqual(PollDecision.completion, pollDecision(true, true, true));
    try std.testing.expectEqual(PollDecision.fatal, pollDecision(false, true, true));
}

test "CAP and request budgets use real timer ticks" {
    try std.testing.expectEqual(@as(u64, 500), ticksFromMilliseconds(1_000, 500));
    try std.testing.expectEqual(@as(u64, 1), ticksFromMilliseconds(250, 1));
    try std.testing.expectEqual(@as(u64, 1), controllerTimeoutTicks(1_000, 0));
    try std.testing.expectEqual(@as(u64, 127_500), controllerTimeoutTicks(1_000, 0xFF));
    try std.testing.expect(requestBudgetTicks(1_000, 10) > ioTimeoutTicks(1_000));
}
