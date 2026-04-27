const std = @import("std");

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

const expectEqual = std.testing.expectEqual;
