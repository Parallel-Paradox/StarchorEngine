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
    registry: *const ComponentRegistry,

    pub fn init(allocator: Allocator, registry: *const ComponentRegistry) Self {
        return .{
            // Impossible to fail since we start with empty bitset.
            .mask = std.DynamicBitSet.initEmpty(allocator, 0) catch unreachable,
            .registry = registry,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mask.deinit();
        self.registry = undefined;
    }

    pub fn clone(self: *const Self, allocator: Allocator) Allocator.Error!Self {
        return .{
            .mask = try self.mask.clone(allocator),
            .registry = self.registry,
        };
    }

    pub const SanityError = error{
        /// The parameters come from a different registry than the one associated with this signature.
        MismatchRegistry,
    };

    pub const EditError = Allocator.Error || SanityError;

    pub fn add(self: *Self, ids: []const ComponentId) EditError!void {
        var check_max_id: ?usize = null;
        for (ids) |id| {
            if (id.registry != self.registry) {
                return EditError.MismatchRegistry;
            }
            if (check_max_id == null or id.val > check_max_id.?) {
                check_max_id = id.val;
            }
        }
        if (check_max_id) |max_id| {
            if (max_id >= self.mask.capacity()) {
                try self.mask.resize(max_id + 1, false);
            }
        }
        for (ids) |id| {
            self.mask.set(id.val);
        }
    }

    /// Always shrink to fit after removing components.
    pub fn remove(self: *Self, ids: []const ComponentId) EditError!void {
        for (ids) |id| {
            if (id.registry != self.registry) {
                return EditError.MismatchRegistry;
            }
        }

        for (ids) |id| {
            if (id.val < self.mask.capacity()) {
                self.mask.unset(id.val);
            }
        }

        // shrink to fit
        if (self.mask.findLastSet()) |last_index| {
            try self.mask.resize(last_index + 1, false);
        } else {
            try self.mask.resize(0, false);
        }
    }

    pub fn has(self: *const Self, id: ComponentId) SanityError!bool {
        if (id.registry != self.registry) {
            return SanityError.MismatchRegistry;
        }
        return id.val < self.mask.capacity() and self.mask.isSet(id.val);
    }

    pub fn contains(self: *const Self, other: *const Self) SanityError!bool {
        if (other.registry != self.registry) {
            return SanityError.MismatchRegistry;
        }
        var it = other.mask.iterator(.{});
        while (it.next()) |bit_index| {
            if (bit_index >= self.mask.capacity() or !self.mask.isSet(bit_index)) {
                return false;
            }
        }
        return true;
    }

    pub fn intersects(self: *const Self, other: *const Self) SanityError!bool {
        if (other.registry != self.registry) {
            return SanityError.MismatchRegistry;
        }
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
const expectError = std.testing.expectError;

const ComponentMeta = ecs.component.ComponentMeta;

test "EntitySignature add/has works and deduplicates naturally by bitset" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id0 = try registry.registerMeta(ComponentMeta.init(u8, .{}));
    const id1 = try registry.registerMeta(ComponentMeta.init(u16, .{}));
    const id2 = try registry.registerMeta(ComponentMeta.init(u32, .{}));

    var sig = EntitySignature.init(std.testing.allocator, &registry);
    defer sig.deinit();

    try sig.add(&.{ id2, id0, id2 });

    try expect(try sig.has(id0));
    try expect(!(try sig.has(id1)));
    try expect(try sig.has(id2));
    try expectEqual(@as(usize, id2.val + 1), sig.mask.capacity());
}

test "EntitySignature remove will unset bits and shrink to fit" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id0 = try registry.registerMeta(ComponentMeta.init(u8, .{}));
    const id1 = try registry.registerMeta(ComponentMeta.init(u16, .{}));
    const id2 = try registry.registerMeta(ComponentMeta.init(u32, .{}));

    var sig = EntitySignature.init(std.testing.allocator, &registry);
    defer sig.deinit();

    try sig.add(&.{ id0, id1, id2 });
    try sig.remove(&.{id2});

    try expect(try sig.has(id0));
    try expect(try sig.has(id1));
    try expect(!(try sig.has(id2)));
    try expectEqual(@as(usize, id1.val + 1), sig.mask.capacity());

    try sig.remove(&.{ id1, id0 });
    try expectEqual(@as(usize, 0), sig.mask.capacity());
}

test "EntitySignature contains and intersects" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id0 = try registry.registerMeta(ComponentMeta.init(u8, .{}));
    const id1 = try registry.registerMeta(ComponentMeta.init(u16, .{}));
    const id2 = try registry.registerMeta(ComponentMeta.init(u32, .{}));

    var a = EntitySignature.init(std.testing.allocator, &registry);
    defer a.deinit();
    var b = EntitySignature.init(std.testing.allocator, &registry);
    defer b.deinit();
    var c = EntitySignature.init(std.testing.allocator, &registry);
    defer c.deinit();

    try a.add(&.{ id0, id2 });
    try b.add(&.{id2});
    try c.add(&.{id1});

    try expect(try a.contains(&b));
    try expect(!(try b.contains(&a)));

    try expect(try a.intersects(&b));
    try expect(!(try a.intersects(&c)));
    try expect(!(try b.intersects(&c)));
}

test "EntitySignature clone creates independent mask with same registry" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const id0 = try registry.registerMeta(ComponentMeta.init(u8, .{}));
    const id1 = try registry.registerMeta(ComponentMeta.init(u16, .{}));

    var original = EntitySignature.init(std.testing.allocator, &registry);
    defer original.deinit();
    try original.add(&.{ id0, id1 });

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit();

    try expect(cloned.registry == original.registry);
    try expect(try cloned.has(id0));
    try expect(try cloned.has(id1));

    try cloned.remove(&.{id1});
    try expect(try original.has(id1));
    try expect(!(try cloned.has(id1)));
}

test "EntitySignature returns MismatchRegistry for cross-registry operations" {
    var registry_a = ComponentRegistry.init(std.testing.allocator);
    defer registry_a.deinit();
    var registry_b = ComponentRegistry.init(std.testing.allocator);
    defer registry_b.deinit();

    const id_a = try registry_a.registerMeta(ComponentMeta.init(u8, .{}));
    const id_b = try registry_b.registerMeta(ComponentMeta.init(u8, .{}));

    var sig_a = EntitySignature.init(std.testing.allocator, &registry_a);
    defer sig_a.deinit();
    var sig_b = EntitySignature.init(std.testing.allocator, &registry_b);
    defer sig_b.deinit();

    try expectError(EntitySignature.EditError.MismatchRegistry, sig_a.add(&.{id_b}));
    try expectError(EntitySignature.EditError.MismatchRegistry, sig_a.remove(&.{id_b}));
    try expectError(EntitySignature.SanityError.MismatchRegistry, sig_a.has(id_b));
    try expectError(EntitySignature.SanityError.MismatchRegistry, sig_a.contains(&sig_b));
    try expectError(EntitySignature.SanityError.MismatchRegistry, sig_a.intersects(&sig_b));

    try sig_a.add(&.{id_a});
    try expect(try sig_a.has(id_a));
}

test "EntitySignature add with empty slice is a no-op" {
    var registry = ComponentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var sig = EntitySignature.init(std.testing.allocator, &registry);
    defer sig.deinit();

    try sig.add(&.{});
    try expectEqual(@as(usize, 0), sig.mask.capacity());
}
