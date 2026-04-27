const std = @import("std");

const Allocator = std.mem.Allocator;

/// A safe wrapper for runtime-aligned buffers.
pub const AlignedBuffer = struct {
    const Self = @This();

    /// Keep original buffer for deallocation.
    original: []u8,
    /// Provide an aligned view of the original buffer.
    aligned: []u8,

    pub fn init(allocator: Allocator, size: usize, alignment: usize) Allocator.Error!Self {
        const original = try allocator.alloc(u8, size + alignment - 1);

        const addr = @intFromPtr(original.ptr);
        const offset = std.mem.alignForward(usize, addr, alignment) - addr;
        const aligned = original[offset .. offset + size];

        return Self{ .original = original, .aligned = aligned };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.original);
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "AlignedBuffer init returns aligned writable slice" {
    const allocator = std.testing.allocator;

    var buffer = try AlignedBuffer.init(allocator, 64, 16);
    defer buffer.deinit(allocator);

    try expectEqual(@as(usize, 64), buffer.aligned.len);
    try expect(@intFromPtr(buffer.aligned.ptr) % 16 == 0);

    @memset(buffer.aligned, 0xAB);
    try expectEqual(@as(u8, 0xAB), buffer.aligned[0]);
    try expectEqual(@as(u8, 0xAB), buffer.aligned[63]);
}

test "AlignedBuffer init supports multiple runtime alignments" {
    const allocator = std.testing.allocator;

    for ([_]usize{ 1, 2, 4, 8, 16, 32, 64 }) |alignment| {
        var buffer = try AlignedBuffer.init(allocator, 17, alignment);
        defer buffer.deinit(allocator);

        try expectEqual(@as(usize, 17), buffer.aligned.len);
        try expect(@intFromPtr(buffer.aligned.ptr) % alignment == 0);
    }
}

test "AlignedBuffer init handles zero-sized buffer" {
    const allocator = std.testing.allocator;

    var buffer = try AlignedBuffer.init(allocator, 0, 8);
    defer buffer.deinit(allocator);

    try expectEqual(@as(usize, 0), buffer.aligned.len);
}
