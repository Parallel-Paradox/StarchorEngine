const std = @import("std");

const root = @import("../root.zig");
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const TypeId = ecs.component.TypeId;
const TypeRegistry = ecs.component.TypeRegistry;
const ComponentId = ecs.component.ComponentId;
const ComponentMeta = ecs.component.ComponentMeta;
const ComponentRegistry = ecs.component.ComponentRegistry;

pub const ArchetypeSignature = ecs.entity.EntitySignature;

pub const ArchetypeMeta = struct {
    const Self = @This();

    pub const Column = struct {
        type_id_val: TypeId.Val,
        comp_id_val: ComponentId.Val,
    };

    pub const ColumnList = std.ArrayList(Column);
    pub const ColumnLookup = std.AutoHashMapUnmanaged(ComponentId.Val, usize);

    allocator: Allocator,
    signature: ArchetypeSignature,
    /// alignment descending > size descending > component_id ascending.
    /// Stable column order used when generating archetype chunk layouts.
    columns: ColumnList,
    column_lookup: ColumnLookup,
    type_registry: *const TypeRegistry,
    comp_registry: *const ComponentRegistry,

    pub const InitError = Allocator.Error || error{
        /// The archetype has no components since type_id_vals and comp_id_vals are empty.
        EmptyArchetype,
        /// The comp_id and type_id of a column come from different types.
        MismatchedTypeAddress,
    };

    pub fn init(
        allocator: Allocator,
        type_registry: *const TypeRegistry,
        comp_registry: *const ComponentRegistry,
        unsorted_columns: []const Column,
    ) InitError!Self {
        if (unsorted_columns.len == 0) {
            return InitError.EmptyArchetype;
        }

        var columns = try ColumnList.initCapacity(allocator, unsorted_columns.len);
        errdefer columns.deinit(allocator);

        for (unsorted_columns) |col| {
            const type_id = TypeId{ .val = col.type_id_val, .registry = type_registry };
            const comp_id = ComponentId{ .val = col.comp_id_val, .registry = comp_registry };
            const type_meta = type_id.meta();
            const comp_meta = comp_id.meta();
            if (type_meta.type_addr.val != comp_meta.type_addr.val) {
                return InitError.MismatchedTypeAddress;
            }
            try columns.append(allocator, col);
        }
        const ColumnsCmp = struct {
            const Context = struct {
                type_registry: *const TypeRegistry,
                comp_registry: *const ComponentRegistry,
            };

            pub fn lessThan(ctx: Context, lhs: Column, rhs: Column) bool {
                const lhs_type_id = TypeId{ .val = lhs.type_id_val, .registry = ctx.type_registry };
                const rhs_type_id = TypeId{ .val = rhs.type_id_val, .registry = ctx.type_registry };
                const lhs_type_meta = lhs_type_id.meta();
                const rhs_type_meta = rhs_type_id.meta();

                if (lhs_type_meta.alignment != rhs_type_meta.alignment) {
                    return lhs_type_meta.alignment > rhs_type_meta.alignment;
                } else if (lhs_type_meta.size != rhs_type_meta.size) {
                    return lhs_type_meta.size > rhs_type_meta.size;
                } else {
                    return lhs.comp_id_val < rhs.comp_id_val;
                }
            }
        };
        std.mem.sort(
            Column,
            columns.items,
            ColumnsCmp.Context{ .type_registry = type_registry, .comp_registry = comp_registry },
            ColumnsCmp.lessThan,
        );

        var signature = ArchetypeSignature.init(allocator);
        errdefer signature.deinit();

        var max_comp_id_val: ComponentId.Val = 0;
        for (columns.items) |col| {
            if (col.comp_id_val > max_comp_id_val) {
                max_comp_id_val = col.comp_id_val;
            }
        }
        try signature.add(&.{max_comp_id_val}); // Reserve capacity for all components in the signature.
        for (columns.items) |col| {
            try signature.add(&.{col.comp_id_val});
        }

        var column_lookup = ColumnLookup.empty;
        errdefer column_lookup.deinit(allocator);

        for (columns.items, 0..) |col, idx| {
            try column_lookup.put(allocator, col.comp_id_val, idx);
        }

        return Self{
            .allocator = allocator,
            .signature = signature,
            .columns = columns,
            .column_lookup = column_lookup,
            .type_registry = type_registry,
            .comp_registry = comp_registry,
        };
    }

    pub fn deinit(self: *Self) void {
        self.signature.deinit();
        self.columns.deinit(self.allocator);
        self.column_lookup.deinit(self.allocator);
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const ArchetypeMetaTestContext = struct {
    const Self = @This();

    type_registry: TypeRegistry,
    comp_registry: ComponentRegistry,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .type_registry = TypeRegistry.init(allocator),
            .comp_registry = ComponentRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.type_registry.deinit();
        self.comp_registry.deinit();
    }

    const MockError = Allocator.Error || ComponentRegistry.Error;
    pub fn mockRegistry(self: *Self) MockError!void {
        _ = try self.type_registry.register(u64);
        _ = try self.type_registry.register([2]u32);
        _ = try self.type_registry.register(u32);
        _ = try self.type_registry.register(i32);

        _ = try self.comp_registry.register(u32, ComponentMeta.init(u32, .{}));
        _ = try self.comp_registry.register([2]u32, ComponentMeta.init([2]u32, .{}));
        _ = try self.comp_registry.register(u64, ComponentMeta.init(u64, .{}));
        _ = try self.comp_registry.register(i32, ComponentMeta.init(i32, .{}));
    }

    pub fn generateMockMeta(self: *Self) (MockError || ArchetypeMeta.InitError)!ArchetypeMeta {
        try self.mockRegistry();

        const columns = [_]ArchetypeMeta.Column{
            .{ .type_id_val = 0, .comp_id_val = 2 }, // u64
            .{ .type_id_val = 1, .comp_id_val = 1 }, // [2]u32
            .{ .type_id_val = 2, .comp_id_val = 0 }, // u32
            .{ .type_id_val = 3, .comp_id_val = 3 }, // i32
        };

        return try ArchetypeMeta.init(
            self.type_registry.allocator,
            &self.type_registry,
            &self.comp_registry,
            &columns,
        );
    }
};

test "ArchetypeMeta init sorts columns and builds signature and lookup" {
    var ctx = ArchetypeMetaTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    var meta = try ctx.generateMockMeta();
    defer meta.deinit();

    try expectEqual(@as(usize, 4), meta.columns.items.len);

    try expectEqual(@as(TypeId.Val, 0), meta.columns.items[0].type_id_val);
    try expectEqual(@as(ComponentId.Val, 2), meta.columns.items[0].comp_id_val);

    try expectEqual(@as(TypeId.Val, 1), meta.columns.items[1].type_id_val);
    try expectEqual(@as(ComponentId.Val, 1), meta.columns.items[1].comp_id_val);

    try expectEqual(@as(TypeId.Val, 2), meta.columns.items[2].type_id_val);
    try expectEqual(@as(ComponentId.Val, 0), meta.columns.items[2].comp_id_val);

    // u32 and i32 share alignment/size; tie-break by component id ascending.
    try expectEqual(@as(TypeId.Val, 3), meta.columns.items[3].type_id_val);
    try expectEqual(@as(ComponentId.Val, 3), meta.columns.items[3].comp_id_val);

    try expect(meta.signature.has(0));
    try expect(meta.signature.has(1));
    try expect(meta.signature.has(2));
    try expect(meta.signature.has(3));
    try expect(!meta.signature.has(4));

    try expectEqual(@as(usize, 0), meta.column_lookup.get(2).?);
    try expectEqual(@as(usize, 1), meta.column_lookup.get(1).?);
    try expectEqual(@as(usize, 2), meta.column_lookup.get(0).?);
    try expectEqual(@as(usize, 3), meta.column_lookup.get(3).?);
    try expect(meta.column_lookup.get(4) == null);
}

test "ArchetypeMeta init returns EmptyArchetype for empty columns" {
    var ctx = ArchetypeMetaTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    try expectError(
        ArchetypeMeta.InitError.EmptyArchetype,
        ArchetypeMeta.init(
            std.testing.allocator,
            &ctx.type_registry,
            &ctx.comp_registry,
            &.{},
        ),
    );
}

test "ArchetypeMeta init returns MismatchedTypeAddress when ids are from different types" {
    var ctx = ArchetypeMetaTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.mockRegistry();

    const columns = [_]ArchetypeMeta.Column{
        .{ .type_id_val = 2, .comp_id_val = 2 },
    };

    try expectError(
        ArchetypeMeta.InitError.MismatchedTypeAddress,
        ArchetypeMeta.init(
            std.testing.allocator,
            &ctx.type_registry,
            &ctx.comp_registry,
            &columns,
        ),
    );
}
