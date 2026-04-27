const std = @import("std");

const root = @import("../root.zig");
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const TypeAddress = ecs.component.TypeAddress;

pub const ComponentId = struct {
    pub const Val = usize;
    pub const INVALID_ID: Val = std.math.maxInt(Val);

    val: Val = INVALID_ID,
    registry: *const ComponentRegistry,

    pub fn equal(self: ComponentId, other: ComponentId) bool {
        return self.val == other.val and self.registry == other.registry;
    }

    /// Make sure the registry is valid and the meta is registered before calling this function.
    pub fn meta(self: ComponentId) ComponentMeta {
        return self.registry.getMeta(self);
    }
};

pub const ComponentMeta = struct {
    pub fn VTable(comptime T: type) type {
        return struct {
            pub const Deinit = *const fn (self: *T) void;
            pub const Move = *const fn (dst: *T, src: *T) void;

            deinit_fn: Deinit = deinit,
            move_fn: Move = move,

            pub fn deinit(_: *T) void {}
            pub fn move(dst: *T, src: *T) void {
                if (T != anyopaque) {
                    @memcpy(std.mem.asBytes(dst), std.mem.asBytes(src));
                } else {
                    @panic("Default move is not supported for opaque types.");
                }
            }
        };
    }

    type_addr: TypeAddress,
    vtable: VTable(anyopaque),

    pub fn init(comptime T: type, comptime vtable: VTable(T)) ComponentMeta {
        const VTableImpl = struct {
            pub fn deinit(self: *anyopaque) void {
                const typed_self: *T = @ptrCast(@alignCast(self));
                return vtable.deinit_fn(typed_self);
            }

            pub fn move(dst: *anyopaque, src: *anyopaque) void {
                const typed_dst: *T = @ptrCast(@alignCast(dst));
                const typed_src: *T = @ptrCast(@alignCast(src));
                return vtable.move_fn(typed_dst, typed_src);
            }
        };

        return ComponentMeta{
            .type_addr = TypeAddress.of(T),
            .vtable = .{
                .deinit_fn = VTableImpl.deinit,
                .move_fn = VTableImpl.move,
            },
        };
    }

    pub fn equal(self: ComponentMeta, other: ComponentMeta) bool {
        return self.vtable.deinit_fn == other.vtable.deinit_fn and self.vtable.move_fn == other.vtable.move_fn;
    }
};

pub const ComponentRegistry = struct {
    const Self = @This();

    allocator: Allocator,
    address_to_id: std.AutoHashMapUnmanaged(TypeAddress, ComponentId.Val),
    meta_list: std.ArrayList(ComponentMeta),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .address_to_id = std.AutoHashMapUnmanaged(TypeAddress, ComponentId.Val).empty,
            .meta_list = std.ArrayList(ComponentMeta).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.address_to_id.deinit(self.allocator);
        self.meta_list.deinit(self.allocator);
    }

    pub const Error = Allocator.Error || error{
        /// The component was already registered with different meta.
        NonIdempotentWrite,
    };

    pub fn register(self: *Self, comptime T: type, meta: ComponentMeta) Error!ComponentId {
        const addr = TypeAddress.of(T);
        const get_id_val = self.address_to_id.get(addr);
        if (get_id_val) |id_val| {
            if (!self.meta_list.items[id_val].equal(meta)) {
                return Error.NonIdempotentWrite;
            }
            return .{ .val = id_val, .registry = self };
        }

        const rv = ComponentId{ .val = self.meta_list.items.len, .registry = self };

        try self.address_to_id.put(self.allocator, addr, rv.val);
        errdefer _ = self.address_to_id.remove(addr);

        try self.meta_list.append(self.allocator, meta);
        errdefer _ = self.meta_list.pop();

        return rv;
    }

    pub fn registerMeta(self: *Self, meta: ComponentMeta) Allocator.Error!ComponentId {
        std.debug.assert(meta.type_addr.val != TypeAddress.INVALID_ADDRESS);

        const rv = ComponentId{ .val = self.meta_list.items.len, .registry = self };

        try self.meta_list.append(self.allocator, meta);
        errdefer _ = self.meta_list.pop();

        return rv;
    }

    pub fn getIdByType(self: *const Self, comptime T: type) ?ComponentId {
        const addr = TypeAddress.of(T);
        return self.getIdByAddress(addr);
    }

    pub fn getIdByAddress(self: *const Self, addr: TypeAddress) ?ComponentId {
        if (self.address_to_id.get(addr)) |id_val| {
            return ComponentId{ .val = id_val, .registry = self };
        } else {
            return null;
        }
    }

    pub fn tryGetMeta(self: *const Self, id: ComponentId) ?ComponentMeta {
        if (id.registry != self or id.val >= self.meta_list.items.len) {
            return null;
        }
        return self.meta_list.items[id.val];
    }

    /// Make sure the id is valid before calling this function.
    pub fn getMeta(self: *const Self, id: ComponentId) ComponentMeta {
        std.debug.assert(id.registry == self);
        std.debug.assert(id.val < self.meta_list.items.len);
        return self.meta_list.items[id.val];
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "ComponentMeta default move copies bytes for non-opaque type" {
    const T = struct {
        a: u32,
        b: u8,
    };

    var src = T{ .a = 42, .b = 7 };
    var dst = T{ .a = 0, .b = 0 };

    const meta = ComponentMeta.init(T, .{});
    meta.vtable.move_fn(@ptrCast(&dst), @ptrCast(&src));

    try expectEqual(@as(u32, 42), dst.a);
    try expectEqual(@as(u8, 7), dst.b);
}

test "ComponentMeta uses custom vtable callbacks" {
    const T = struct {
        value: i32,
    };

    const Impl = struct {
        fn deinit(self: *T) void {
            self.value = -1;
        }

        fn move(dst: *T, src: *T) void {
            dst.value = src.value + 10;
        }
    };

    var src = T{ .value = 5 };
    var dst = T{ .value = 0 };

    const meta = ComponentMeta.init(T, .{
        .deinit_fn = Impl.deinit,
        .move_fn = Impl.move,
    });

    meta.vtable.move_fn(@ptrCast(&dst), @ptrCast(&src));
    try expectEqual(@as(i32, 15), dst.value);

    meta.vtable.deinit_fn(@ptrCast(&dst));
    try expectEqual(@as(i32, -1), dst.value);
}

test "register is idempotent for same type when meta is identical" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const T = struct {
        value: i32,
    };

    const Meta = struct {
        fn deinit(_: *T) void {}
        fn move(dst: *T, src: *T) void {
            dst.value = src.value + 1;
        }
    };

    const meta = ComponentMeta.init(T, .{
        .deinit_fn = Meta.deinit,
        .move_fn = Meta.move,
    });

    const id1 = try registry.register(T, meta);
    const id2 = try registry.register(T, meta);

    try expect(id1.equal(id2));
    try expect(id1.registry == &registry);

    const stored = id1.meta();
    try expect(stored.equal(meta));

    var src = T{ .value = 2 };
    var dst = T{ .value = 0 };
    stored.vtable.move_fn(@ptrCast(&dst), @ptrCast(&src));
    try expectEqual(@as(i32, 3), dst.value);

    const lookup = registry.getIdByType(T).?;
    try expect(lookup.equal(id1));
}

test "register returns NonIdempotentWrite for same type with different meta" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const T = struct {
        value: i32,
    };

    const MetaA = struct {
        fn deinit(_: *T) void {}
        fn move(dst: *T, src: *T) void {
            dst.value = src.value;
        }
    };

    const MetaB = struct {
        fn deinit(_: *T) void {}
        fn move(dst: *T, src: *T) void {
            dst.value = src.value + 100;
        }
    };

    const meta_a = ComponentMeta.init(T, .{
        .deinit_fn = MetaA.deinit,
        .move_fn = MetaA.move,
    });
    const meta_b = ComponentMeta.init(T, .{
        .deinit_fn = MetaB.deinit,
        .move_fn = MetaB.move,
    });

    const id = try registry.register(T, meta_a);
    try expectError(ComponentRegistry.Error.NonIdempotentWrite, registry.register(T, meta_b));

    const stored = id.meta();
    try expect(stored.equal(meta_a));
}

test "register assigns consecutive ids for new types" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id_a = try registry.register(u8, ComponentMeta.init(u8, .{}));
    const id_b = try registry.register(i16, ComponentMeta.init(i16, .{}));

    try expectEqual(@as(ComponentId.Val, 0), id_a.val);
    try expectEqual(@as(ComponentId.Val, 1), id_b.val);
}

test "getId returns null for unregistered type" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try expect(registry.getIdByType(u64) == null);
}

test "registerMeta appends metadata without adding typed lookup entry" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const meta_id = try registry.registerMeta(ComponentMeta.init(u32, .{}));
    _ = meta_id.meta();

    try expectEqual(@as(u32, 0), registry.address_to_id.size);
    try expect(registry.getIdByType(u32) == null);
}

test "ComponentId equality includes registry identity" {
    var registry_a = ComponentRegistry.init(std.testing.allocator);
    defer registry_a.deinit();

    var registry_b = ComponentRegistry.init(std.testing.allocator);
    defer registry_b.deinit();

    const id_a = try registry_a.register(u8, ComponentMeta.init(u8, .{}));
    const id_b = try registry_b.register(u8, ComponentMeta.init(u8, .{}));

    try expect(!id_a.equal(id_b));
}

test "tryGetMeta returns null for invalid component id" {
    var registry_a = ComponentRegistry.init(std.testing.allocator);
    defer registry_a.deinit();

    var registry_b = ComponentRegistry.init(std.testing.allocator);
    defer registry_b.deinit();

    const T = struct { value: i32 };
    const id_a = try registry_a.register(T, ComponentMeta.init(T, .{}));
    try expect(registry_b.tryGetMeta(id_a) == null);

    const invalid_index = ComponentId{ .val = id_a.val + 1, .registry = &registry_a };
    try expect(registry_a.tryGetMeta(invalid_index) == null);
}
