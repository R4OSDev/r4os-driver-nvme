//! Actual DMA lease release order. An unacknowledged descriptor stays owned.
const std = @import("std");
pub const Result = enum { released, mapping_retained, pin_retained };
pub fn release(ctx: anytype, mapping: anytype, pin: anytype) Result {
    if (mapping.handle != 0) {
        if (ctx.unmapDma(mapping) != 0 or mapping.handle != 0) return .mapping_retained;
    }
    if (pin.handle != 0) {
        if (ctx.unpinDmaBuffer(pin) != 0 or pin.handle != 0) return .pin_retained;
    }
    return .released;
}
const Descriptor = struct { handle: u32 };
const Fake = struct {
    map_result: i32 = 0,
    pin_result: i32 = 0,
    clear_map: bool = true,
    clear_pin: bool = true,
    calls: [2]u8 = .{ 0, 0 },
    count: usize = 0,
    pub fn unmapDma(self: *@This(), mapping: *Descriptor) i32 {
        self.calls[self.count] = 1;
        self.count += 1;
        if (self.map_result == 0 and self.clear_map) mapping.handle = 0;
        return self.map_result;
    }
    pub fn unpinDmaBuffer(self: *@This(), pin: *Descriptor) i32 {
        self.calls[self.count] = 2;
        self.count += 1;
        if (self.pin_result == 0 and self.clear_pin) pin.handle = 0;
        return self.pin_result;
    }
};
test "real lease release orders unmap before unpin and clears only acknowledged descriptors" {
    var ctx = Fake{};
    var mapping = Descriptor{ .handle = 11 };
    var pin = Descriptor{ .handle = 22 };
    try std.testing.expectEqual(Result.released, release(&ctx, &mapping, &pin));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &ctx.calls);
    try std.testing.expectEqual(@as(u32, 0), mapping.handle);
    try std.testing.expectEqual(@as(u32, 0), pin.handle);
}
test "unmap failure or incomplete acknowledgment never reaches unpin" {
    for ([_]Fake{ .{ .map_result = -2 }, .{ .clear_map = false } }) |value| {
        var ctx = value;
        var mapping = Descriptor{ .handle = 11 };
        var pin = Descriptor{ .handle = 22 };
        try std.testing.expectEqual(Result.mapping_retained, release(&ctx, &mapping, &pin));
        try std.testing.expectEqual(@as(usize, 1), ctx.count);
        try std.testing.expectEqual(@as(u32, 11), mapping.handle);
        try std.testing.expectEqual(@as(u32, 22), pin.handle);
    }
}
test "unpin failure keeps its identity after acknowledged unmap" {
    for ([_]Fake{ .{ .pin_result = -3 }, .{ .clear_pin = false } }) |value| {
        var ctx = value;
        var mapping = Descriptor{ .handle = 11 };
        var pin = Descriptor{ .handle = 22 };
        try std.testing.expectEqual(Result.pin_retained, release(&ctx, &mapping, &pin));
        try std.testing.expectEqual(@as(usize, 2), ctx.count);
        try std.testing.expectEqual(@as(u32, 0), mapping.handle);
        try std.testing.expectEqual(@as(u32, 22), pin.handle);
    }
}
test "empty descriptors cause no release calls" {
    var ctx = Fake{};
    var mapping = Descriptor{ .handle = 0 };
    var pin = Descriptor{ .handle = 0 };
    try std.testing.expectEqual(Result.released, release(&ctx, &mapping, &pin));
    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}
