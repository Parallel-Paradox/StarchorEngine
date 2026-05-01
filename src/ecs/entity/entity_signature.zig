const std = @import("std");

const root = @import("../root.zig");
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const ComponentId = ecs.component.ComponentId;
const ComponentRegistry = ecs.component.ComponentRegistry;

pub const EntitySignature = struct {
    mask: std.DynamicBitSet,
    hash: u64,

    pub fn init(allocator: Allocator) @This() {
        return @This(){
            // Impossible to fail since we start with empty bitset.
            .mask = std.DynamicBitSet.initEmpty(allocator, 0) catch unreachable,
            .hash = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.mask.deinit();
        self.hash = 0;
    }

    pub fn clone(self: *const @This(), allocator: Allocator) Allocator.Error!@This() {
        return @This(){
            .mask = try self.mask.clone(allocator),
            .hash = self.hash,
        };
    }

    fn rehash(self: *@This()) void {
        const last_bit = self.mask.unmanaged.findLastSet() orelse 0;
        const last_mask = last_bit / @sizeOf(std.DynamicBitSetUnmanaged.MaskInt);
        self.hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(self.mask.unmanaged.masks[0 .. last_mask + 1]));
    }

    pub fn equal(self: @This(), other: @This()) bool {
        return self.hash == other.hash and self.mask.eql(other.mask);
    }

    pub fn add(self: *@This(), ids: []const ComponentId.Val) Allocator.Error!void {
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
        self.rehash();
    }

    /// Always shrink to fit after removing components.
    pub fn remove(self: *@This(), ids: []const ComponentId.Val) Allocator.Error!void {
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

        self.rehash();
    }

    pub fn has(self: *const @This(), id: ComponentId.Val) bool {
        return id < self.mask.capacity() and self.mask.isSet(id);
    }

    pub fn contains(self: *const @This(), other: *const @This()) bool {
        var it = other.mask.iterator(.{});
        while (it.next()) |bit_index| {
            if (bit_index >= self.mask.capacity() or !self.mask.isSet(bit_index)) {
                return false;
            }
        }
        return true;
    }

    pub fn intersects(self: *const @This(), other: *const @This()) bool {
        var it = self.mask.iterator(.{});
        while (it.next()) |bit_index| {
            if (bit_index < other.mask.capacity() and other.mask.isSet(bit_index)) {
                return true;
            }
        }
        return false;
    }

    pub const HashContext = struct {
        pub fn hash(_: @This(), key: EntitySignature) u64 {
            return key.hash;
        }

        pub fn eql(_: @This(), lhs: EntitySignature, rhs: EntitySignature) bool {
            return lhs.equal(rhs);
        }
    };
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

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

test "EntitySignature hash matches for equal signatures" {
    var a = EntitySignature.init(std.testing.allocator);
    defer a.deinit();
    var b = EntitySignature.init(std.testing.allocator);
    defer b.deinit();

    try a.add(&.{ 1, 4, 7, 12 });
    try b.add(&.{ 12, 1 });
    try b.add(&.{ 7, 4 });

    try expectEqual(a.hash, b.hash);
    try expect(a.equal(b));
}

test "EntitySignature hash updates after mutation" {
    var signature = EntitySignature.init(std.testing.allocator);
    defer signature.deinit();

    try signature.add(&.{ 1, 4 });
    const base_hash = signature.hash;

    try signature.add(&.{9});
    try expect(signature.hash != base_hash);

    try signature.remove(&.{9});
    try expectEqual(base_hash, signature.hash);
}
