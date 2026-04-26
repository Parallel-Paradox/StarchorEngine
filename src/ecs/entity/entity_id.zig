const std = @import("std");
const ecs = @import("../root.zig");

const Allocator = std.mem.Allocator;
const ComponentId = ecs.component.ComponentId;
const ComponentRegistry = ecs.component.ComponentRegistry;

pub const EntityId = struct {
    pub const INVALID_ID: usize = std.math.maxInt(usize);
    pub const TOMB_GENERATION: usize = std.math.maxInt(usize);

    val: usize = INVALID_ID,
    generation: usize = TOMB_GENERATION,
};

pub const EntitySignature = struct {
    const Self = @This();

    mask: std.DynamicBitSet,

    pub fn init(allocator: Allocator) Self {
        return .{
            // Impossible to fail since we start with empty bitset.
            .mask = std.DynamicBitSet.initEmpty(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mask.deinit();
    }

    pub fn clone(self: *const Self, allocator: Allocator) Allocator.Error!Self {
        return .{
            .mask = try self.mask.clone(allocator),
        };
    }

    pub fn add(self: *Self, ids: []const ComponentId.Val) Allocator.Error!void {
        var check_max_id: ?usize = null;
        for (ids) |id| {
            if (check_max_id == null or id > check_max_id.?) {
                check_max_id = id;
            }
        }
        if (check_max_id) |max_id| {
            if (max_id >= self.mask.capacity()) {
                try self.mask.resize(max_id + 1, false);
            }
        }
        for (ids) |id| {
            self.mask.set(id);
        }
    }

    /// Always shrink to fit after removing components.
    pub fn remove(self: *Self, ids: []const ComponentId.Val) Allocator.Error!void {
        for (ids) |id| {
            if (id < self.mask.capacity()) {
                self.mask.unset(id);
            }
        }

        // shrink to fit
        if (self.mask.findLastSet()) |last_index| {
            try self.mask.resize(last_index + 1, false);
        } else {
            try self.mask.resize(0, false);
        }
    }

    pub fn has(self: *const Self, id: ComponentId.Val) bool {
        return id < self.mask.capacity() and self.mask.isSet(id);
    }

    pub fn contains(self: *const Self, other: *const Self) bool {
        var it = other.mask.iterator(.{});
        while (it.next()) |bit_index| {
            if (bit_index >= self.mask.capacity() or !self.mask.isSet(bit_index)) {
                return false;
            }
        }
        return true;
    }

    pub fn intersects(self: *const Self, other: *const Self) bool {
        var it = self.mask.iterator(.{});
        while (it.next()) |bit_index| {
            if (bit_index < other.mask.capacity() and other.mask.isSet(bit_index)) {
                return true;
            }
        }
        return false;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "EntityId default is tombstone sentinel" {
    const id = EntityId{};
    try expectEqual(EntityId.INVALID_ID, id.val);
    try expectEqual(EntityId.TOMB_GENERATION, id.generation);
}

test "EntitySignature add and has" {
    var signature = EntitySignature.init(std.testing.allocator);
    defer signature.deinit();

    try signature.add(&.{ 1, 4, 7 });

    try expect(signature.has(1));
    try expect(signature.has(4));
    try expect(signature.has(7));
    try expect(!signature.has(0));
    try expect(!signature.has(8));
}

test "EntitySignature remove unset bits and shrink capacity" {
    var signature = EntitySignature.init(std.testing.allocator);
    defer signature.deinit();

    try signature.add(&.{ 1, 4, 7 });
    try expectEqual(@as(usize, 8), signature.mask.capacity());

    try signature.remove(&.{7});
    try expect(!signature.has(7));
    try expectEqual(@as(usize, 5), signature.mask.capacity());

    try signature.remove(&.{ 1, 4 });
    try expectEqual(@as(usize, 0), signature.mask.capacity());
}

test "EntitySignature contains checks subset relation" {
    var a = EntitySignature.init(std.testing.allocator);
    defer a.deinit();
    var b = EntitySignature.init(std.testing.allocator);
    defer b.deinit();

    try a.add(&.{ 1, 3, 5 });
    try b.add(&.{ 1, 5 });

    try expect(a.contains(&b));
    try expect(!b.contains(&a));

    try b.add(&.{9});
    try expect(!a.contains(&b));
}

test "EntitySignature intersects detects overlap" {
    var a = EntitySignature.init(std.testing.allocator);
    defer a.deinit();
    var b = EntitySignature.init(std.testing.allocator);
    defer b.deinit();

    try a.add(&.{ 2, 4 });
    try b.add(&.{6});
    try expect(!a.intersects(&b));

    try b.add(&.{4});
    try expect(a.intersects(&b));
}

test "EntitySignature clone is independent copy" {
    var signature = EntitySignature.init(std.testing.allocator);
    defer signature.deinit();
    try signature.add(&.{ 1, 8 });

    var cloned = try signature.clone(std.testing.allocator);
    defer cloned.deinit();

    try expect(cloned.has(1));
    try expect(cloned.has(8));

    try signature.remove(&.{8});
    try expect(!signature.has(8));
    try expect(cloned.has(8));
}
