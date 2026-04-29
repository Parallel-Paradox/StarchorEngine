const std = @import("std");

const root = @import("../root.zig");
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const TypeRegistry = ecs.component.TypeRegistry;
const ComponentRegistry = ecs.component.ComponentRegistry;
const ComponentMeta = ecs.component.ComponentMeta;
const EntityId = ecs.entity.EntityId;

pub const Archetype = struct {
    const Self = @This();

    pub const Meta = ecs.entity.ArchetypeMeta;
    pub const Chunk = ecs.entity.ArchetypeChunk;

    /// 16KB
    pub const MAX_CHUNK_BYTE_LEN = 16 * 1024;

    /// Responsible for meta, layout, and array. But the chunks inside array should expose its own allocator.
    allocator: Allocator,
    meta: *Meta,
    layout: *Chunk.Layout,
    chunks: std.ArrayList(Chunk),
    len: usize,

    const InitError = Allocator.Error || Meta.InitError;

    pub fn init(
        allocator: Allocator,
        type_registry: *TypeRegistry,
        comp_registry: *ComponentRegistry,
        unsorted_columns: []const Meta.Column,
    ) InitError!Self {
        const meta = try allocator.create(Meta);
        errdefer allocator.destroy(meta);
        meta.* = try Meta.init(allocator, type_registry, comp_registry, unsorted_columns);

        const layout = try allocator.create(Chunk.Layout);
        errdefer allocator.destroy(layout);
        layout.* = try Chunk.Layout.init(allocator, meta);
        errdefer layout.deinit();

        return Self{
            .allocator = allocator,
            .meta = meta,
            .layout = layout,
            .chunks = std.ArrayList(Chunk).empty,
            .len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
        self.len = 0;

        self.layout.deinit();
        self.allocator.destroy(self.layout);

        self.meta.deinit();
        self.allocator.destroy(self.meta);
    }

    fn ensureNotFull(self: *Self, gpa: Allocator, chunk_allocator: Allocator) Allocator.Error!void {
        if (self.chunks.items.len == 0) {
            self.layout.resetCapacity(1);
            var chunk = try Chunk.init(chunk_allocator, self.layout);
            errdefer chunk.deinit();
            try self.chunks.append(self.allocator, chunk);
            return;
        }

        if (self.chunks.getLast().len < self.layout.capacity) {
            return;
        }

        // Extend the chunk if it's the only one.
        if (self.chunks.items.len == 1) {
            const old_chunk = &self.chunks.items[0];

            const eid = old_chunk.getEntityIds();

            const col_len = self.meta.columns.items.len;
            var columns = try std.ArrayList(Chunk.ColumnBuffer).initCapacity(gpa, col_len);
            defer columns.deinit(gpa);
            for (0..col_len) |col_id| {
                try columns.append(gpa, old_chunk.getColumn(col_id));
            }

            const new_layout = try self.allocator.create(Chunk.Layout);
            errdefer self.allocator.destroy(new_layout);
            new_layout.* = try Chunk.Layout.init(self.allocator, self.meta);
            errdefer new_layout.deinit();

            if (self.layout.byteLen() * 2 <= MAX_CHUNK_BYTE_LEN) {
                // Double the capacity, not full for sure after extension.
                new_layout.resetCapacity(self.layout.capacity * 2);
            } else {
                // Extend the chunk to max, but still need to check whether it's full.
                new_layout.resetByteLen(MAX_CHUNK_BYTE_LEN);
            }

            if (new_layout.capacity == self.layout.capacity) {
                new_layout.deinit();
                self.allocator.destroy(new_layout);
            } else {
                var new_chunk = try Chunk.init(chunk_allocator, new_layout);
                errdefer new_chunk.deinit();

                _ = new_chunk.push(eid, columns.items); // Surely won't fail since we just extended the buffer.
                old_chunk.len = 0;
                old_chunk.deinit();
                old_chunk.* = new_chunk;

                self.layout.deinit();
                self.allocator.destroy(self.layout);
                self.layout = new_layout;
                return;
            }
        }

        // Create a new chunk if the last one is full.
        var chunk = try Chunk.init(chunk_allocator, self.layout);
        errdefer chunk.deinit();
        try self.chunks.append(self.allocator, chunk);
        return;
    }

    pub const PushErrInfo = struct {
        pushed_count: usize,
    };

    /// Use gpa to allocate temporary buffers, and chunk_allocator to allocate new `ArchetypeChunk` if needed.
    pub fn push(
        self: *Self,
        gpa: Allocator,
        chunk_allocator: Allocator,
        eid: []EntityId,
        columns: []Chunk.ColumnBuffer,
        err_info: ?*PushErrInfo,
    ) Allocator.Error!void {
        const push_count = eid.len;
        if (push_count == 0) {
            return;
        }

        var pushed_count: usize = 0;
        defer self.len += pushed_count;
        errdefer if (err_info) |info| {
            info.pushed_count = pushed_count;
        };

        var push_eid = eid;
        var push_columns = try std.ArrayList(Chunk.ColumnBuffer).initCapacity(gpa, columns.len);
        defer push_columns.deinit(gpa);
        for (columns) |col| {
            try push_columns.append(gpa, col);
        }
        while (pushed_count < push_count) {
            try self.ensureNotFull(gpa, chunk_allocator);
            var chunk_id = self.chunks.items.len - 1;
            // If chunk_id == 0, just use it since we have ensured it's not full.
            while (chunk_id > 1 and self.chunks.items[chunk_id - 1].len < self.layout.capacity) {
                chunk_id -= 1;
            }
            const chunk = &self.chunks.items[chunk_id];
            const push_result = chunk.push(push_eid, push_columns.items);
            pushed_count += push_result;
            push_eid = push_eid[push_result..];
            for (push_columns.items) |*col| {
                col.bytes = col.bytes[push_result * col.stride ..];
                col.capacity -= push_result;
            }
        }
    }

    /// Buffer are filled with the tail of chunk. Return the count of entities that are successfully popped.
    /// Use gpa to allocate temporary buffers.
    pub fn pop(self: *Self, gpa: Allocator, eid: []EntityId, columns: []?Chunk.ColumnBuffer) Allocator.Error!usize {
        const pop_count = @min(eid.len, self.len);
        if (pop_count == 0) {
            return 0;
        }

        var popped_count: usize = 0;
        defer self.len -= popped_count;

        var chunk_id = (self.len - 1) / self.layout.capacity;
        var pop_eid = eid;
        var pop_columns = try std.ArrayList(?Chunk.ColumnBuffer).initCapacity(gpa, columns.len);
        defer pop_columns.deinit(gpa);
        for (columns) |col| {
            try pop_columns.append(gpa, col);
        }
        while (popped_count < pop_count) {
            const chunk = &self.chunks.items[chunk_id];
            const pop_result = chunk.pop(pop_eid, pop_columns.items);
            popped_count += pop_result;
            pop_eid = pop_eid[pop_result..];
            for (pop_columns.items) |*col_op| {
                if (col_op.*) |*col| {
                    col.bytes = col.bytes[pop_result * col.stride ..];
                    col.capacity -= pop_result;
                }
            }
            if (chunk_id > 0) {
                chunk_id -= 1;
            }
            if (chunk_id < self.chunks.items.len - 1) { // chunks len >= 1
                // Keep only the last empty chunk to avoid frequent allocations, deinit the rest.
                var tail = self.chunks.pop().?;
                tail.deinit();
            }
        }
        return popped_count;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const ArchetypeTestContext = struct {
    const Self = @This();

    type_registry: TypeRegistry,
    comp_registry: ComponentRegistry,

    pub fn init(allocator: Allocator) Self {
        return .{
            .type_registry = TypeRegistry.init(allocator),
            .comp_registry = ComponentRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.type_registry.deinit();
        self.comp_registry.deinit();
    }

    const RegisterError = Allocator.Error || ComponentRegistry.Error;

    pub fn registerBasicColumns(self: *Self) RegisterError![2]Archetype.Meta.Column {
        const tid_u64 = try self.type_registry.register(u64);
        const tid_u32 = try self.type_registry.register(u32);
        const cid_u64 = try self.comp_registry.register(u64, ComponentMeta.init(u64, .{}));
        const cid_u32 = try self.comp_registry.register(u32, ComponentMeta.init(u32, .{}));

        return .{
            .{ .type_id_val = tid_u32.val, .comp_id_val = cid_u32.val },
            .{ .type_id_val = tid_u64.val, .comp_id_val = cid_u64.val },
        };
    }

    pub fn makeBasicArchetype(self: *Self) (RegisterError || Archetype.Meta.InitError)!Archetype {
        const cols = try self.registerBasicColumns();
        return try Archetype.init(std.testing.allocator, &self.type_registry, &self.comp_registry, &cols);
    }

    pub fn makeSingleColumnArchetype(
        self: *Self,
        comptime T: type,
    ) (RegisterError || Archetype.Meta.InitError)!Archetype {
        const tid = try self.type_registry.register(T);
        const cid = try self.comp_registry.register(T, ComponentMeta.init(T, .{}));
        const cols = [_]Archetype.Meta.Column{.{ .type_id_val = tid.val, .comp_id_val = cid.val }};
        return try Archetype.init(std.testing.allocator, &self.type_registry, &self.comp_registry, &cols);
    }
};

test "Archetype push supports empty input" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    var archetype = try ctx.makeBasicArchetype();
    defer archetype.deinit();

    try archetype.push(std.testing.allocator, std.testing.allocator, &.{}, &.{}, null);
    try expectEqual(@as(usize, 0), archetype.len);
    try expectEqual(@as(usize, 0), archetype.chunks.items.len);
}

test "Archetype push allocates first chunk and then extends single chunk" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    var archetype = try ctx.makeBasicArchetype();
    defer archetype.deinit();

    var ids_a = [_]EntityId{.{ .val = 1, .generation = 1 }};
    var col_u64_a = [_]u64{101};
    var col_u32_a = [_]u32{11};
    var cols_a = [_]Archetype.Chunk.ColumnBuffer{
        Archetype.Chunk.ColumnBuffer.init(u64, col_u64_a[0..]),
        Archetype.Chunk.ColumnBuffer.init(u32, col_u32_a[0..]),
    };
    try archetype.push(std.testing.allocator, std.testing.allocator, ids_a[0..], cols_a[0..], null);

    try expectEqual(@as(usize, 1), archetype.chunks.items.len);
    try expectEqual(@as(usize, 1), archetype.layout.capacity);
    try expectEqual(@as(usize, 1), archetype.len);

    var ids_b = [_]EntityId{.{ .val = 2, .generation = 1 }};
    var col_u64_b = [_]u64{202};
    var col_u32_b = [_]u32{22};
    var cols_b = [_]Archetype.Chunk.ColumnBuffer{
        Archetype.Chunk.ColumnBuffer.init(u64, col_u64_b[0..]),
        Archetype.Chunk.ColumnBuffer.init(u32, col_u32_b[0..]),
    };
    try archetype.push(std.testing.allocator, std.testing.allocator, ids_b[0..], cols_b[0..], null);

    try expectEqual(@as(usize, 1), archetype.chunks.items.len);
    try expectEqual(@as(usize, 2), archetype.layout.capacity);
    try expectEqual(@as(usize, 2), archetype.len);

    const ids = archetype.chunks.items[0].getEntityIds();
    try expectEqual(@as(usize, 1), ids[0].val);
    try expectEqual(@as(usize, 2), ids[1].val);
}

test "Archetype ensureNotFull appends chunk when max byte len cannot increase capacity" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    const Huge = [9000]u8;
    var archetype = try ctx.makeSingleColumnArchetype(Huge);
    defer archetype.deinit();

    var ids_a = [_]EntityId{.{ .val = 1, .generation = 1 }};
    var huge_a = [_]Huge{[_]u8{1} ** 9000};
    var cols_a = [_]Archetype.Chunk.ColumnBuffer{Archetype.Chunk.ColumnBuffer.init(Huge, huge_a[0..])};
    try archetype.push(std.testing.allocator, std.testing.allocator, ids_a[0..], cols_a[0..], null);
    const old_byte_len = archetype.layout.byteLen();

    var ids_b = [_]EntityId{.{ .val = 2, .generation = 1 }};
    var huge_b = [_]Huge{[_]u8{2} ** 9000};
    var cols_b = [_]Archetype.Chunk.ColumnBuffer{Archetype.Chunk.ColumnBuffer.init(Huge, huge_b[0..])};
    try archetype.push(std.testing.allocator, std.testing.allocator, ids_b[0..], cols_b[0..], null);

    try expectEqual(old_byte_len, archetype.layout.byteLen());
    try expectEqual(@as(usize, 2), archetype.chunks.items.len);
    try expectEqual(@as(usize, 1), archetype.chunks.items[0].len);
    try expectEqual(@as(usize, 1), archetype.chunks.items[1].len);

    var ids_c = [_]EntityId{.{ .val = 3, .generation = 1 }};
    var huge_c = [_]Huge{[_]u8{3} ** 9000};
    var cols_c = [_]Archetype.Chunk.ColumnBuffer{Archetype.Chunk.ColumnBuffer.init(Huge, huge_c[0..])};
    try archetype.push(std.testing.allocator, std.testing.allocator, ids_c[0..], cols_c[0..], null);

    try expectEqual(@as(usize, 3), archetype.chunks.items.len);
    try expectEqual(@as(usize, 3), archetype.len);
}

test "Archetype push keeps insertion order across growth" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    var archetype = try ctx.makeBasicArchetype();
    defer archetype.deinit();

    var ids = [_]EntityId{
        .{ .val = 1, .generation = 1 },
        .{ .val = 2, .generation = 1 },
        .{ .val = 3, .generation = 1 },
        .{ .val = 4, .generation = 1 },
        .{ .val = 5, .generation = 1 },
    };
    var col_u64 = [_]u64{ 10, 20, 30, 40, 50 };
    var col_u32 = [_]u32{ 1, 2, 3, 4, 5 };
    var cols = [_]Archetype.Chunk.ColumnBuffer{
        Archetype.Chunk.ColumnBuffer.init(u64, col_u64[0..]),
        Archetype.Chunk.ColumnBuffer.init(u32, col_u32[0..]),
    };
    try archetype.push(std.testing.allocator, std.testing.allocator, ids[0..], cols[0..], null);

    try expect(archetype.chunks.items.len >= 1);
    try expectEqual(@as(usize, 5), archetype.len);

    var got: usize = 0;
    for (archetype.chunks.items) |chunk| {
        const chunk_ids = chunk.getEntityIds();
        for (chunk_ids) |eid| {
            got += 1;
            try expectEqual(got, eid.val);
        }
    }
}

test "Archetype pop on empty archetype returns zero" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    var archetype = try ctx.makeBasicArchetype();
    defer archetype.deinit();

    var out_ids = [_]EntityId{.{}};
    var out_u64 = [_]u64{0};
    var out_u32 = [_]u32{0};
    var out_cols = [_]?Archetype.Chunk.ColumnBuffer{
        Archetype.Chunk.ColumnBuffer.init(u64, out_u64[0..]),
        Archetype.Chunk.ColumnBuffer.init(u32, out_u32[0..]),
    };

    const popped = try archetype.pop(std.testing.allocator, out_ids[0..], out_cols[0..]);
    try expectEqual(@as(usize, 0), popped);
    try expectEqual(@as(usize, 0), archetype.len);
    try expectEqual(@as(usize, 0), archetype.chunks.items.len);
}

test "Archetype pop across chunks returns tail-first and shrinks chunks" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    const Huge = [9000]u8;
    var archetype = try ctx.makeSingleColumnArchetype(Huge);
    defer archetype.deinit();

    var in_ids = [_]EntityId{
        .{ .val = 10, .generation = 1 },
        .{ .val = 20, .generation = 1 },
        .{ .val = 30, .generation = 1 },
    };
    var in_huge = [_]Huge{
        [_]u8{10} ** 9000,
        [_]u8{20} ** 9000,
        [_]u8{30} ** 9000,
    };
    var in_cols = [_]Archetype.Chunk.ColumnBuffer{Archetype.Chunk.ColumnBuffer.init(Huge, in_huge[0..])};
    try archetype.push(std.testing.allocator, std.testing.allocator, in_ids[0..], in_cols[0..], null);
    try expectEqual(@as(usize, 3), archetype.chunks.items.len);

    var out_ids = [_]EntityId{ .{}, .{} };
    var out_huge = [_]Huge{ [_]u8{0} ** 9000, [_]u8{0} ** 9000 };
    var out_cols = [_]?Archetype.Chunk.ColumnBuffer{Archetype.Chunk.ColumnBuffer.init(Huge, out_huge[0..])};
    const popped = try archetype.pop(std.testing.allocator, out_ids[0..], out_cols[0..]);

    try expectEqual(@as(usize, 2), popped);
    try expectEqual(@as(usize, 1), archetype.len);
    try expectEqual(@as(usize, 1), archetype.chunks.items.len);
    try expectEqual(@as(usize, 30), out_ids[0].val);
    try expectEqual(@as(usize, 20), out_ids[1].val);
}

test "Archetype pop supports null column outputs" {
    var ctx = ArchetypeTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    var archetype = try ctx.makeBasicArchetype();
    defer archetype.deinit();

    var in_ids = [_]EntityId{
        .{ .val = 1, .generation = 1 },
        .{ .val = 2, .generation = 1 },
    };
    var in_u64 = [_]u64{ 9, 8 };
    var in_u32 = [_]u32{ 7, 6 };
    var in_cols = [_]Archetype.Chunk.ColumnBuffer{
        Archetype.Chunk.ColumnBuffer.init(u64, in_u64[0..]),
        Archetype.Chunk.ColumnBuffer.init(u32, in_u32[0..]),
    };
    try archetype.push(std.testing.allocator, std.testing.allocator, in_ids[0..], in_cols[0..], null);

    var out_ids = [_]EntityId{.{}};
    var out_cols = [_]?Archetype.Chunk.ColumnBuffer{ null, null };
    const popped = try archetype.pop(std.testing.allocator, out_ids[0..], out_cols[0..]);

    try expectEqual(@as(usize, 1), popped);
    try expectEqual(@as(usize, 2), out_ids[0].val);
    try expectEqual(@as(usize, 1), archetype.len);
}
