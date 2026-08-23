const std = @import("std");

pub const Queue = enum {
    admin,
    io,
};

pub const Phase = enum {
    cold,
    initializing,
    ready,
    recovering,
    failed,
    stopped,
};

pub const Completion = enum {
    current,
    stale,
    unexpected,
};

pub const PollDecision = enum {
    completion,
    fatal,
    timeout,
    wait,
};

const Pending = struct {
    active: bool = false,
    cid: u16 = 0,
    generation: u32 = 0,
    start_tick: u64 = 0,
    timeout_ticks: u64 = 0,
};

/// Software-side identity and deadline state for the two NVMe queues.
///
/// The controller is used synchronously today, but Admin Abort may be issued
/// while one I/O command is still outstanding.  Keeping one tracker per queue
/// therefore matters even before deeper queueing is introduced.  Queue reset
/// advances `generation`, so a CID from a pre-reset command can never become a
/// current command merely because the 16-bit CID counter wrapped.
pub const Machine = struct {
    phase: Phase = .cold,
    generation: u32 = 1,
    admin: Pending = .{},
    io: Pending = .{},
    recoveries: u64 = 0,
    recovery_failures: u64 = 0,

    pub fn markInitializing(self: *Machine) void {
        self.phase = .initializing;
    }

    pub fn markReady(self: *Machine) void {
        self.phase = .ready;
    }

    pub fn markFailed(self: *Machine) void {
        self.phase = .failed;
    }

    pub fn markStopped(self: *Machine) void {
        self.clear(.admin);
        self.clear(.io);
        self.phase = .stopped;
    }

    pub fn begin(
        self: *Machine,
        queue: Queue,
        cid: u16,
        start_tick: u64,
        timeout_ticks: u64,
    ) bool {
        const command = self.pending(queue);
        if (command.active or cid == 0 or timeout_ticks == 0) return false;
        command.* = .{
            .active = true,
            .cid = cid,
            .generation = self.generation,
            .start_tick = start_tick,
            .timeout_ticks = timeout_ticks,
        };
        return true;
    }

    pub fn classify(self: *const Machine, queue: Queue, cid: u16) Completion {
        const command = self.pendingConst(queue);
        if (!command.active) return .unexpected;
        if (command.generation != self.generation or command.cid != cid) return .stale;
        return .current;
    }

    pub fn expired(self: *const Machine, queue: Queue, now: u64) bool {
        const command = self.pendingConst(queue);
        return command.active and deadlineExpired(command.start_tick, command.timeout_ticks, now);
    }

    pub fn currentCid(self: *const Machine, queue: Queue) ?u16 {
        const command = self.pendingConst(queue);
        return if (command.active and command.generation == self.generation) command.cid else null;
    }

    pub fn complete(self: *Machine, queue: Queue, cid: u16) bool {
        if (self.classify(queue, cid) != .current) return false;
        self.clear(queue);
        return true;
    }

    pub fn clear(self: *Machine, queue: Queue) void {
        self.pending(queue).* = .{};
    }

    pub fn beginRecovery(self: *Machine) bool {
        if (self.phase == .recovering or self.phase == .stopped) return false;
        self.phase = .recovering;
        self.recoveries +|= 1;
        return true;
    }

    /// Called only after CSTS.RDY is observed clear.  At that point the old
    /// controller generation can no longer access queue or payload memory.
    pub fn resetQueues(self: *Machine) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.clear(.admin);
        self.clear(.io);
    }

    pub fn finishRecovery(self: *Machine, ok: bool) void {
        if (ok) {
            self.phase = .ready;
        } else {
            self.phase = .failed;
            self.recovery_failures +|= 1;
        }
    }

    fn pending(self: *Machine, queue: Queue) *Pending {
        return switch (queue) {
            .admin => &self.admin,
            .io => &self.io,
        };
    }

    fn pendingConst(self: *const Machine, queue: Queue) *const Pending {
        return switch (queue) {
            .admin => &self.admin,
            .io => &self.io,
        };
    }
};

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

/// CAP.TO is expressed directly in 500 ms units (FFh == 127.5 s).  A zero
/// value receives one timer tick of observation tolerance, rather than
/// turning the transition back into an unbounded wait.
pub fn controllerTimeoutTicks(timer_hz: u32, timeout_units: u8) u64 {
    return @max(@as(u64, 1), ticksFromMilliseconds(timer_hz, @as(u64, timeout_units) * 500));
}

pub fn adminTimeoutTicks(timer_hz: u32) u64 {
    return @max(@as(u64, 1), ticksFromMilliseconds(timer_hz, 5_000));
}

pub fn ioTimeoutTicks(timer_hz: u32) u64 {
    return @max(@as(u64, 1), ticksFromMilliseconds(timer_hz, 5_000));
}

/// Upper bound advertised to Blockcore for one synchronous I/O including a
/// first attempt, Abort, disable/enable, both queue-create commands, one replay
/// and one final controller cleanup.  Saturating arithmetic preserves a finite
/// bound even with an implausible timer frequency.
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

test "millisecond and CAP timeouts use real timer ticks" {
    try std.testing.expectEqual(@as(u64, 500), ticksFromMilliseconds(1_000, 500));
    try std.testing.expectEqual(@as(u64, 1), ticksFromMilliseconds(250, 1));
    try std.testing.expectEqual(@as(u64, 1), controllerTimeoutTicks(1_000, 0));
    try std.testing.expectEqual(@as(u64, 127_500), controllerTimeoutTicks(1_000, 0xFF));
}

test "deadline comparison remains monotone across tick wrap" {
    const start = std.math.maxInt(u64) - 2;
    try std.testing.expect(!deadlineExpired(start, 4, 0));
    try std.testing.expect(deadlineExpired(start, 4, 1));
}

test "CID and queue generation distinguish current and stale completions" {
    var machine: Machine = .{};
    machine.markInitializing();
    try std.testing.expect(machine.begin(.io, 7, 100, 10));
    try std.testing.expectEqual(Completion.stale, machine.classify(.io, 6));
    try std.testing.expectEqual(Completion.current, machine.classify(.io, 7));
    try std.testing.expect(!machine.expired(.io, 109));
    try std.testing.expect(machine.expired(.io, 110));

    try std.testing.expect(machine.beginRecovery());
    machine.resetQueues();
    machine.finishRecovery(true);
    try std.testing.expectEqual(Phase.ready, machine.phase);
    try std.testing.expectEqual(Completion.unexpected, machine.classify(.io, 7));
    try std.testing.expect(machine.begin(.io, 7, 200, 10));
    try std.testing.expect(machine.complete(.io, 7));
}

test "failed recovery is terminal and counted" {
    var machine: Machine = .{ .phase = .ready };
    try std.testing.expect(machine.beginRecovery());
    machine.resetQueues();
    machine.finishRecovery(false);
    try std.testing.expectEqual(Phase.failed, machine.phase);
    try std.testing.expectEqual(@as(u64, 1), machine.recoveries);
    try std.testing.expectEqual(@as(u64, 1), machine.recovery_failures);
}

test "deterministic delayed lost and fatal completions have bounded outcomes" {
    try std.testing.expectEqual(PollDecision.wait, pollDecision(false, false, false));
    try std.testing.expectEqual(PollDecision.completion, pollDecision(true, false, false));
    try std.testing.expectEqual(PollDecision.timeout, pollDecision(false, false, true));
    try std.testing.expectEqual(PollDecision.fatal, pollDecision(false, true, false));
    try std.testing.expectEqual(PollDecision.completion, pollDecision(true, true, true));
}
