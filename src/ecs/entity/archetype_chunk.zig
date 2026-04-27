const std = @import("std");

const root = @import("../root.zig");
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const ArchetypeMeta = ecs.entity.ArchetypeMeta;

test "the principle of type erasure" {
    var slice = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const ptr = &slice[0];
    const ptr_int = @intFromPtr(ptr);
    const aligned_ptr_int = std.mem.alignForward(usize, ptr_int, @alignOf(u32));
    const align_padding = aligned_ptr_int - ptr_int;
    const aligned_ptr = &slice[align_padding];
    const resized_ptr: *u32 = @ptrCast(@alignCast(aligned_ptr));
    resized_ptr.* = 1;

    // Little-endian
    try expectEqual(1, slice[align_padding]);
}

pub const ArchetypeChunk = struct {
    const Self = @This();

    pub const Layout = struct {
        allocator: Allocator,
        meta: *const ArchetypeMeta,
        capacity: usize,
        bytes_len: usize,
        alignment: usize,
        column_offsets: std.ArrayList(usize),
        entity_id_offset: usize,
    };

    allocator: Allocator,
    layout: *const Layout,
    bytes: []u8,
    len: usize,

    pub fn init(allocator: Allocator, layout: *const Layout) Allocator.Error!Self {
        return Self{
            .allocator = allocator,
            .layout = layout,
            .bytes = try allocator.rawAlloc(),
        };
    }
};

const expectEqual = std.testing.expectEqual;
