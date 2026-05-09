const std = @import("std");

const root = @import("../root.zig");
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const ComponentId = ecs.component.ComponentId;
const TypeRegistry = ecs.component.TypeRegistry;
const ComponentRegistry = ecs.component.ComponentRegistry;
const Archetype = ecs.entity.Archetype;
const ArchetypeSignature = ecs.entity.ArchetypeSignature;

pub const ArchetypeId = struct {
    pub const INVALID_ID: usize = std.math.maxInt(usize);
    pub const TOMB_GENERATION: usize = std.math.maxInt(usize);

    val: usize = INVALID_ID,
    generation: usize = TOMB_GENERATION,

    pub fn equal(self: @This(), other: @This()) bool {
        return self.val == other.val and self.generation == other.generation;
    }
};

pub const ArchetypeRegistry = struct {
    const ArchetypeLookup = std.HashMapUnmanaged(
        // The memory of signature is managed by `ArchetypeMeta`, no need to clone or deinit.
        ArchetypeSignature,
        ArchetypeId,
        ArchetypeSignature.HashContext,
        std.hash_map.default_max_load_percentage,
    );

    allocator: Allocator,
    type_registry: *const TypeRegistry,
    comp_registry: *const ComponentRegistry,
    unused_ids: std.ArrayList(ArchetypeId) = .empty,
    sparse_dense: std.ArrayList(usize) = .empty,
    archetypes: std.ArrayList(Archetype) = .empty,
    archetype_lookup: ArchetypeLookup = .empty,

    pub fn init(
        allocator: Allocator,
        type_registry: *const TypeRegistry,
        comp_registry: *const ComponentRegistry,
    ) @This() {
        return @This(){
            .allocator = allocator,
            .type_registry = type_registry,
            .comp_registry = comp_registry,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.archetype_lookup.deinit(self.allocator);
        for (self.archetypes.items) |*archetype| {
            archetype.deinit();
        }
        self.archetypes.deinit(self.allocator);
        self.unused_ids.deinit(self.allocator);
        self.sparse_dense.deinit(self.allocator);
    }

    pub fn register(
        self: *@This(),
        gpa: Allocator,
        archetype_allocator: Allocator,
        sig: ArchetypeSignature,
    ) Allocator.Error!ArchetypeId {
        std.debug.assert(sig.mask.count() > 0); // Empty archetype is not allowed.

        if (self.lookup(sig)) |id| {
            return id;
        }

        const dense_id = self.archetypes.items.len;
        var id = ArchetypeId{};
        if (self.unused_ids.items.len > 0) {
            id = self.unused_ids.pop().?;
            id.generation += 1;
            std.debug.assert(id.generation != ArchetypeId.TOMB_GENERATION);
            self.sparse_dense.items[id.val] = dense_id;
        } else {
            id.val = self.sparse_dense.items.len;
            id.generation = 0;

            try self.sparse_dense.append(self.allocator, dense_id);
            errdefer _ = self.sparse_dense.pop();
        }

        var unsorted_columns = try std.ArrayList(Archetype.Meta.Column).initCapacity(gpa, sig.mask.count());
        defer unsorted_columns.deinit(gpa);

        var iter = sig.mask.iterator(.{});
        while (iter.next()) |comp_id_val| {
            const comp_id = ComponentId{ .val = comp_id_val, .registry = self.comp_registry };
            const type_addr = comp_id.meta().type_addr;
            const type_id = self.type_registry.getIdByAddress(type_addr).?;
            try unsorted_columns.append(gpa, .{ .type_id_val = type_id.val, .comp_id_val = comp_id.val });
        }

        var archetype = try Archetype.init(
            archetype_allocator,
            id,
            self.type_registry,
            self.comp_registry,
            unsorted_columns.items,
        );
        errdefer archetype.deinit();

        try self.archetypes.append(self.allocator, archetype);
        errdefer _ = self.archetypes.pop();

        try self.archetype_lookup.put(self.allocator, archetype.meta.signature, id);
        errdefer _ = self.archetype_lookup.remove(archetype.meta.signature);

        return id;
    }

    pub fn unregister(self: *@This(), id: ArchetypeId) Allocator.Error!void {
        std.debug.assert(id.val < self.sparse_dense.items.len);
        const dense_id = self.sparse_dense.items[id.val];

        std.debug.assert(dense_id < self.archetypes.items.len);
        var archetype = self.archetypes.swapRemove(dense_id);
        _ = self.archetype_lookup.remove(archetype.meta.signature);
        archetype.deinit();

        if (dense_id < self.archetypes.items.len) {
            const sparse_id = self.archetypes.items[dense_id].meta.id.val;
            std.debug.assert(sparse_id < self.sparse_dense.items.len);
            self.sparse_dense.items[sparse_id] = dense_id;
        }
        self.sparse_dense.items[id.val] = ArchetypeId.INVALID_ID;
        try self.unused_ids.append(self.allocator, id);
    }

    pub fn lookup(self: @This(), sig: ArchetypeSignature) ?ArchetypeId {
        return self.archetype_lookup.get(sig);
    }

    pub fn get(self: @This(), id: ArchetypeId) *Archetype {
        std.debug.assert(id.val < self.sparse_dense.items.len);
        const dense_id = self.sparse_dense.items[id.val];
        std.debug.assert(dense_id < self.archetypes.items.len);
        return &self.archetypes.items[dense_id];
    }
};

const ComponentMeta = ecs.component.ComponentMeta;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const ArchetypeRegistryTestContext = struct {
    allocator: Allocator,
    type_registry: TypeRegistry,
    comp_registry: ComponentRegistry,

    pub fn init(allocator: Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .type_registry = TypeRegistry.init(allocator),
            .comp_registry = ComponentRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.comp_registry.deinit();
        self.type_registry.deinit();
    }

    pub fn registerComponent(self: *@This(), comptime T: type) (Allocator.Error || ComponentRegistry.Error)!ComponentId {
        _ = try self.type_registry.register(T);
        return try self.comp_registry.register(T, ComponentMeta.init(T, .{}));
    }

    pub fn makeSignature(self: *@This(), ids: []const ComponentId) Allocator.Error!ArchetypeSignature {
        var sig = ArchetypeSignature.init(self.allocator);
        errdefer sig.deinit();

        for (ids) |id| {
            try sig.add(&.{id.val});
        }
        return sig;
    }
};

test "ArchetypeRegistry register/lookup/get are consistent and idempotent" {
    var ctx = ArchetypeRegistryTestContext.init(std.testing.allocator);
    defer ctx.deinit();
    var registry = ArchetypeRegistry.init(std.testing.allocator, &ctx.type_registry, &ctx.comp_registry);
    defer registry.deinit();

    const cid_u32 = try ctx.registerComponent(u32);
    const cid_u64 = try ctx.registerComponent(u64);

    var sig = try ctx.makeSignature(&.{ cid_u32, cid_u64 });
    defer sig.deinit();

    const id1 = try registry.register(std.testing.allocator, std.testing.allocator, sig);
    const id2 = try registry.register(std.testing.allocator, std.testing.allocator, sig);

    try expect(id1.equal(id2));
    try expectEqual(@as(usize, 1), registry.archetypes.items.len);

    const lookup_id = registry.lookup(sig).?;
    try expect(lookup_id.equal(id1));

    const archetype = registry.get(id1);
    try expect(archetype.meta.id.equal(id1));
    try expect(archetype.meta.signature.equal(sig));
}

test "ArchetypeRegistry unregister updates mappings and reused id bumps generation" {
    var ctx = ArchetypeRegistryTestContext.init(std.testing.allocator);
    defer ctx.deinit();
    var registry = ArchetypeRegistry.init(std.testing.allocator, &ctx.type_registry, &ctx.comp_registry);
    defer registry.deinit();

    const cid_a = try ctx.registerComponent(u8);
    const cid_b = try ctx.registerComponent(u16);
    const cid_c = try ctx.registerComponent(u32);

    var sig_a = try ctx.makeSignature(&.{cid_a});
    defer sig_a.deinit();
    var sig_b = try ctx.makeSignature(&.{cid_b});
    defer sig_b.deinit();
    var sig_c = try ctx.makeSignature(&.{ cid_a, cid_c });
    defer sig_c.deinit();

    const id_a = try registry.register(std.testing.allocator, std.testing.allocator, sig_a);
    const id_b = try registry.register(std.testing.allocator, std.testing.allocator, sig_b);
    try expectEqual(@as(usize, 2), registry.archetypes.items.len);

    try registry.unregister(id_a);
    try expect(registry.lookup(sig_a) == null);

    const id_b_after = registry.lookup(sig_b).?;
    try expect(id_b_after.equal(id_b));
    try expect(registry.get(id_b).meta.signature.equal(sig_b));

    const id_c = try registry.register(std.testing.allocator, std.testing.allocator, sig_c);
    try expectEqual(id_a.val, id_c.val);
    try expectEqual(id_a.generation + 1, id_c.generation);
    try expect(registry.lookup(sig_c).?.equal(id_c));
    try expect(registry.get(id_c).meta.signature.equal(sig_c));
}
