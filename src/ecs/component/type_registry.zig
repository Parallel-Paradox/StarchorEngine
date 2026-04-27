const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TypeAddress = struct {
    val: usize,

    pub fn of(comptime T: type) TypeAddress {
        const S = struct {
            const Type = T; // Instantiate per type to get unique address
            var dummy: u8 = 0;
        };
        return TypeAddress{ .val = @intFromPtr(&S.dummy) };
    }
};

pub const TypeId = struct {
    pub const Val = usize;
    pub const INVALID_ID: Val = std.math.maxInt(Val);

    val: Val = INVALID_ID,
    registry: *const TypeRegistry,

    pub fn equal(self: TypeId, other: TypeId) bool {
        return self.val == other.val and self.registry == other.registry;
    }

    pub fn tryGetMeta(self: TypeId) ?TypeMeta {
        return self.registry.tryGetMeta(self);
    }

    /// Make sure the registry is valid and the meta is registered before calling this function.
    pub fn getMeta(self: TypeId) TypeMeta {
        return self.registry.getMeta(self);
    }
};

pub const TypeMeta = struct {
    size: usize,
    alignment: usize,
    name: []const u8,

    pub fn init(comptime T: type) TypeMeta {
        return TypeMeta{ .size = @sizeOf(T), .alignment = @alignOf(T), .name = @typeName(T) };
    }
};

pub const TypeRegistry = struct {
    const Self = @This();

    allocator: Allocator,
    address_to_id: std.AutoHashMapUnmanaged(usize, TypeId.Val),
    meta_list: std.ArrayList(TypeMeta),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .address_to_id = std.AutoHashMapUnmanaged(usize, TypeId.Val).empty,
            .meta_list = std.ArrayList(TypeMeta).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.address_to_id.deinit(self.allocator);
        self.meta_list.deinit(self.allocator);
    }

    pub fn register(self: *Self, comptime T: type) Allocator.Error!TypeId {
        const addr = TypeAddress.of(T);
        const get_id_val = self.address_to_id.get(addr.val);
        if (get_id_val) |id_val| {
            return .{ .val = id_val, .registry = self };
        }

        const rv = TypeId{ .val = self.meta_list.items.len, .registry = self };

        try self.address_to_id.put(self.allocator, addr.val, rv.val);
        errdefer _ = self.address_to_id.remove(addr.val);

        const meta = TypeMeta.init(T);
        try self.meta_list.append(self.allocator, meta);
        errdefer _ = self.meta_list.pop();

        return rv;
    }

    pub fn registerMeta(self: *Self, meta: TypeMeta) Allocator.Error!TypeId {
        const rv = TypeId{ .val = self.meta_list.items.len, .registry = self };

        try self.meta_list.append(self.allocator, meta);
        errdefer _ = self.meta_list.pop();

        return rv;
    }

    pub fn getId(self: *const Self, comptime T: type) ?TypeId {
        const addr = TypeAddress.of(T);
        if (self.address_to_id.get(addr.val)) |id_val| {
            return TypeId{ .val = id_val, .registry = self };
        } else {
            return null;
        }
    }

    pub fn tryGetMeta(self: *const Self, id: TypeId) ?TypeMeta {
        if (id.registry != self or id.val >= self.meta_list.items.len) {
            return null;
        }
        return self.meta_list.items[id.val];
    }

    /// Make sure the id is valid before calling this function.
    pub fn getMeta(self: *const Self, id: TypeId) TypeMeta {
        std.debug.assert(id.registry == self);
        std.debug.assert(id.val < self.meta_list.items.len);
        return self.meta_list.items[id.val];
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "TypeAddress is stable per type and distinct across different types" {
    const a1 = TypeAddress.of(u32);
    const a2 = TypeAddress.of(u32);
    const b = TypeAddress.of(i32);

    try expectEqual(a1.val, a2.val);
    try expect(a1.val != b.val);
}

test "register returns stable id for same type and stores correct meta" {
    var registry = TypeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id1 = try registry.register(u32);
    const id2 = try registry.register(u32);

    try expect(id1.equal(id2));
    try expect(id1.registry == &registry);

    const meta = id1.getMeta();
    try expectEqual(@sizeOf(u32), meta.size);
    try expectEqual(@alignOf(u32), meta.alignment);
    try expectEqualStrings(@typeName(u32), meta.name);

    const lookup = registry.getId(u32).?;
    try expect(lookup.equal(id1));
}

test "register assigns consecutive ids for new types" {
    var registry = TypeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id_a = try registry.register(u8);
    const id_b = try registry.register(i16);

    try expectEqual(@as(TypeId.Val, 0), id_a.val);
    try expectEqual(@as(TypeId.Val, 1), id_b.val);
}

test "getId returns null for unregistered type" {
    var registry = TypeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try expect(registry.getId(u64) == null);
}

test "registerMeta appends metadata without adding typed lookup entry" {
    var registry = TypeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const meta = TypeMeta{
        .size = 13,
        .alignment = 1,
        .name = "custom.meta",
    };

    const meta_id = try registry.registerMeta(meta);
    const stored_meta = meta_id.getMeta();
    try expectEqual(@as(usize, 13), stored_meta.size);
    try expectEqual(@as(usize, 1), stored_meta.alignment);
    try expectEqualStrings("custom.meta", stored_meta.name);

    try expectEqual(@as(u32, 0), registry.address_to_id.size);
}

test "TypeId equality includes registry identity" {
    var registry_a = TypeRegistry.init(std.testing.allocator);
    defer registry_a.deinit();

    var registry_b = TypeRegistry.init(std.testing.allocator);
    defer registry_b.deinit();

    const id_a = try registry_a.register(u8);
    const id_b = try registry_b.register(u8);

    try expect(!id_a.equal(id_b));
}

test "tryGetMeta returns null for invalid type id" {
    var registry_a = TypeRegistry.init(std.testing.allocator);
    defer registry_a.deinit();

    var registry_b = TypeRegistry.init(std.testing.allocator);
    defer registry_b.deinit();

    const id_a = try registry_a.register(u8);
    try expect(registry_b.tryGetMeta(id_a) == null);

    const invalid_index = TypeId{ .val = id_a.val + 1, .registry = &registry_a };
    try expect(registry_a.tryGetMeta(invalid_index) == null);
}
