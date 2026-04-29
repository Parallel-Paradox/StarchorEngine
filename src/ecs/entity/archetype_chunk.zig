const std = @import("std");

const root = @import("../root.zig");
const base = root.base;
const ecs = root.ecs;

const Allocator = std.mem.Allocator;
const ArchetypeMeta = ecs.entity.ArchetypeMeta;
const TypeId = ecs.component.TypeId;
const TypeRegistry = ecs.component.TypeRegistry;
const ComponentId = ecs.component.ComponentId;
const ComponentMeta = ecs.component.ComponentMeta;
const ComponentRegistry = ecs.component.ComponentRegistry;
const EntityId = ecs.entity.EntityId;
const AlignedBuffer = base.mem.AlignedBuffer;

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
        buffer_size: usize,
        buffer_alignment: usize,
        column_offsets: std.ArrayList(usize),
        entity_id_offset: usize,

        pub fn init(allocator: Allocator, meta: *const ArchetypeMeta) Allocator.Error!Layout {
            var column_offsets = try std.ArrayList(usize).initCapacity(allocator, meta.columns.items.len);
            errdefer column_offsets.deinit(allocator);
            for (0..meta.columns.items.len) |_| {
                try column_offsets.append(allocator, 0);
            }

            // According to `ArchetypeMeta.init`, `meta` is always non-empty, and columns are ordered by descending
            // alignment, so the first column component has the largest alignment.
            const eid_align = @alignOf(EntityId);
            const first_type_id = TypeId{ .val = meta.columns.items[0].type_id_val, .registry = meta.type_registry };
            const first_align = first_type_id.meta().alignment;
            const buffer_alignment = @max(eid_align, first_align);

            return .{
                .allocator = allocator,
                .meta = meta,
                .capacity = 0,
                .buffer_size = 0,
                .buffer_alignment = buffer_alignment,
                .column_offsets = column_offsets,
                .entity_id_offset = 0,
            };
        }

        pub fn deinit(self: *Layout) void {
            self.column_offsets.deinit(self.allocator);
        }

        /// Reset layout with a given entity capacity.
        pub fn resetCapacity(self: *Layout, capacity: usize) void {
            self.capacity = capacity;
            std.debug.assert(self.column_offsets.items.len == self.meta.columns.items.len);

            // Since all descending alignment is ordered and suppose to be power of 2, there is no padding between
            // columns, so we can just pack them one by one.
            self.buffer_size = 0;
            for (self.meta.columns.items, self.column_offsets.items) |col_meta, *col_offset| {
                col_offset.* = self.buffer_size;
                const col_type_id = TypeId{ .val = col_meta.type_id_val, .registry = self.meta.type_registry };
                const col_size = col_type_id.meta().size;
                self.buffer_size += col_size * capacity;
            }

            // Put EntityId at the end of buffer.
            self.buffer_size = std.mem.alignForward(usize, self.buffer_size, @alignOf(EntityId));
            self.entity_id_offset = self.buffer_size;
            self.buffer_size += @sizeOf(EntityId) * capacity;
        }

        /// Reset layout with a given buffer original byte length.
        pub fn resetByteLen(self: *Layout, byte_len: usize) void {
            self.buffer_size = AlignedBuffer.originalToAligned(byte_len, self.buffer_alignment);
            std.debug.assert(self.column_offsets.items.len == self.meta.columns.items.len);

            const eid_size = @sizeOf(EntityId);
            const eid_align = @alignOf(EntityId);

            // Calculate the byte size that an entity actually need.
            var per_entity_size: usize = eid_size;
            for (self.meta.columns.items) |col| {
                const col_type_id = TypeId{ .val = col.type_id_val, .registry = self.meta.type_registry };
                const col_size = col_type_id.meta().size;
                per_entity_size += col_size;
            }

            // Put EntityId at the end of buffer.
            const buffer_end = std.mem.alignBackward(usize, self.buffer_size, eid_align);
            self.capacity = buffer_end / per_entity_size;
            self.entity_id_offset = buffer_end - self.capacity * eid_size;

            // Since all descending alignment is ordered and suppose to be power of 2, there is no padding between
            // columns, so we can just pack them one by one.
            var offset: usize = 0;
            for (self.meta.columns.items, self.column_offsets.items) |col_meta, *col_offset| {
                col_offset.* = offset;
                const type_id = TypeId{ .val = col_meta.type_id_val, .registry = self.meta.type_registry };
                const stride = type_id.meta().size;
                offset += stride * self.capacity;
            }
        }

        pub fn byteLen(self: *Layout) usize {
            return AlignedBuffer.alignedToOriginal(self.buffer_size, self.buffer_alignment);
        }
    };

    allocator: Allocator,
    layout: *const Layout,
    buffer: AlignedBuffer,
    /// The count of entities currently stored in the chunk. Always less than or equal to `layout.capacity`.
    len: usize,

    pub fn init(allocator: Allocator, layout: *const Layout) Allocator.Error!Self {
        std.debug.assert(layout.column_offsets.items.len > 0); // Empty layout is not allowed.
        return Self{
            .allocator = allocator,
            .layout = layout,
            .buffer = try AlignedBuffer.init(allocator, layout.buffer_size, layout.buffer_alignment),
            .len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.removeTail(self.len);
        self.buffer.deinit(self.allocator);
    }

    /// Get the slice of EntityId that contains unoccupied slots. Used for writing new entities.
    pub fn getEntityIdsUnsafe(self: Self) []EntityId {
        const offset = self.layout.entity_id_offset;
        const stride = @sizeOf(EntityId);
        const bytes = self.buffer.aligned[offset..][0 .. stride * self.layout.capacity];
        const aligned_bytes: []align(@alignOf(EntityId)) u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(EntityId, aligned_bytes);
    }

    /// Get the slice of EntityId that contains only occupied slots. Always safe to read.
    pub fn getEntityIds(self: Self) []EntityId {
        const ids = self.getEntityIdsUnsafe();
        return ids[0..self.len];
    }

    pub const ColumnBuffer = struct {
        bytes: []u8,
        stride: usize,
        capacity: usize,

        pub fn init(comptime T: type, vals: []T) ArchetypeChunk.ColumnBuffer {
            return .{
                .bytes = std.mem.sliceAsBytes(vals),
                .stride = @sizeOf(T),
                .capacity = vals.len,
            };
        }
    };

    /// Get the slice of the given column index that contains unoccupied slots. Used for writing new components.
    pub fn getColumnUnsafe(self: Self, col_id: usize) ColumnBuffer {
        const offset = self.layout.column_offsets.items[col_id];
        const type_id_val = self.layout.meta.columns.items[col_id].type_id_val;
        const type_id = TypeId{ .val = type_id_val, .registry = self.layout.meta.type_registry };
        const stride = type_id.meta().size;
        const bytes = self.buffer.aligned[offset..][0 .. stride * self.layout.capacity];
        return .{ .bytes = bytes, .stride = stride, .capacity = self.layout.capacity };
    }

    /// Get the slice of the given column index that contains only occupied slots. Always safe to read.
    pub fn getColumn(self: Self, col_id: usize) ColumnBuffer {
        const column = self.getColumnUnsafe(col_id);
        const occupied_bytes = column.bytes[0 .. column.stride * self.len];
        return .{ .bytes = occupied_bytes, .stride = column.stride, .capacity = self.len };
    }

    /// Buffer are pushed from front to back. Return the count of entities that are successfully pushed.
    pub fn push(self: *Self, eid: []EntityId, columns: []ColumnBuffer) usize {
        std.debug.assert(columns.len > 0);
        std.debug.assert(columns.len == self.layout.column_offsets.items.len);
        std.debug.assert(columns.len == self.layout.meta.columns.items.len);

        if (self.len >= self.layout.capacity) {
            return 0;
        }

        const capacity = self.layout.capacity - self.len;
        const push_count = eid.len;
        const pushed_count: usize = @min(capacity, push_count);
        defer self.len += pushed_count;

        const comp_registry = self.layout.meta.comp_registry;
        for (columns, self.layout.column_offsets.items, self.layout.meta.columns.items) |push_col, offset, col_meta| {
            std.debug.assert(push_col.capacity == push_count); // Assume all columns have the same capacity.
            const comp_id = ComponentId{ .val = col_meta.comp_id_val, .registry = comp_registry };
            const comp_meta = comp_id.meta();
            const move_fn = comp_meta.vtable.move_fn;
            const stride = push_col.stride;
            const dst = self.buffer.aligned[offset..][self.len * stride ..][0 .. stride * pushed_count];
            const src = push_col.bytes[0 .. stride * pushed_count];
            for (0..pushed_count) |i| {
                const dst_slice = dst[i * stride ..][0..stride];
                const src_slice = src[i * stride ..][0..stride];
                move_fn(@ptrCast(@alignCast(dst_slice.ptr)), @ptrCast(@alignCast(src_slice.ptr)));
            }
        }

        const dst = self.getEntityIdsUnsafe()[self.len..][0..pushed_count];
        const src = eid[0..pushed_count];
        for (0..pushed_count) |i| {
            dst[i] = src[i];
        }

        return pushed_count;
    }

    /// Buffer are filled with the tail of chunk. Return the count of entities that are successfully popped.
    pub fn pop(self: *Self, eid: []EntityId, columns: []?ColumnBuffer) usize {
        std.debug.assert(columns.len > 0);
        std.debug.assert(columns.len == self.layout.column_offsets.items.len);
        std.debug.assert(columns.len == self.layout.meta.columns.items.len);

        if (self.len == 0) {
            return 0;
        }

        const pop_count = eid.len;
        const popped_count: usize = @min(self.len, pop_count);
        defer self.len -= popped_count;

        const comp_registry = self.layout.meta.comp_registry;
        for (
            columns,
            self.layout.column_offsets.items,
            self.layout.meta.columns.items,
            0..,
        ) |pop_col, offset, col_meta, col_id| {
            const comp_id = ComponentId{ .val = col_meta.comp_id_val, .registry = comp_registry };
            const comp_meta = comp_id.meta();
            const deinit_fn = comp_meta.vtable.deinit_fn;
            const move_fn = comp_meta.vtable.move_fn;
            if (pop_col == null) {
                const src = self.getColumn(col_id);
                for (0..popped_count) |i| {
                    const begin = (self.len - popped_count + i) * src.stride;
                    const src_slice = src.bytes[begin..][0..src.stride];
                    deinit_fn(@ptrCast(@alignCast(src_slice.ptr)));
                }
                continue;
            }
            std.debug.assert(pop_col.?.capacity == pop_count); // Assume all columns have the same capacity.
            const stride = pop_col.?.stride;
            const dst = pop_col.?.bytes[0 .. stride * popped_count];
            const begin = (self.len - popped_count) * stride;
            const src = self.buffer.aligned[offset..][begin..][0 .. stride * popped_count];
            for (0..popped_count) |i| {
                const dst_slice = dst[i * stride ..][0..stride];
                const src_slice = src[i * stride ..][0..stride];
                move_fn(@ptrCast(@alignCast(dst_slice.ptr)), @ptrCast(@alignCast(src_slice.ptr)));
            }
        }

        const dst = eid[0..popped_count];
        const begin = self.len - popped_count;
        const src = self.getEntityIdsUnsafe()[begin..][0..popped_count];
        for (0..popped_count) |i| {
            dst[i] = src[i];
        }
        return popped_count;
    }

    pub fn removeTail(self: *Self, rm_cnt: usize) void {
        const removed = @min(rm_cnt, self.len);
        if (removed == 0) {
            return;
        }

        const type_registry = self.layout.meta.type_registry;
        const comp_registry = self.layout.meta.comp_registry;
        for (self.layout.meta.columns.items, self.layout.column_offsets.items) |col, offset| {
            const type_id = TypeId{ .val = col.type_id_val, .registry = type_registry };
            const comp_id = ComponentId{ .val = col.comp_id_val, .registry = comp_registry };
            const stride = type_id.meta().size;
            const column_slice = self.buffer.aligned[offset..][stride * (self.len - removed) .. stride * self.len];
            const deinit_fn = comp_id.meta().vtable.deinit_fn;
            for (0..removed) |i| {
                const comp_slice = column_slice[i * stride ..][0..stride];
                deinit_fn(@ptrCast(@alignCast(comp_slice.ptr)));
            }
        }
        self.len -= removed;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const ArchetypeChunkTestContext = struct {
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

    pub fn makeMeta(
        self: *Self,
        columns: []const ArchetypeMeta.Column,
    ) (Allocator.Error || ArchetypeMeta.InitError)!ArchetypeMeta {
        return ArchetypeMeta.init(self.type_registry.allocator, &self.type_registry, &self.comp_registry, columns);
    }

    pub fn makeLayout(meta: *const ArchetypeMeta, capacity: usize) Allocator.Error!ArchetypeChunk.Layout {
        var layout = try ArchetypeChunk.Layout.init(std.testing.allocator, meta);
        layout.resetCapacity(capacity);
        return layout;
    }

    const RegisterError = Allocator.Error || ComponentRegistry.Error;

    pub fn registerBasicColumns(self: *Self) RegisterError![2]ArchetypeMeta.Column {
        const tid_u64 = try self.type_registry.register(u64);
        const tid_u32 = try self.type_registry.register(u32);
        const cid_u64 = try self.comp_registry.register(u64, ComponentMeta.init(u64, .{}));
        const cid_u32 = try self.comp_registry.register(u32, ComponentMeta.init(u32, .{}));

        return .{
            .{ .type_id_val = tid_u32.val, .comp_id_val = cid_u32.val },
            .{ .type_id_val = tid_u64.val, .comp_id_val = cid_u64.val },
        };
    }

    pub fn makeSingleColumnMeta(
        self: *Self,
        comptime T: type,
        comp_meta: ComponentMeta,
    ) (RegisterError || ArchetypeMeta.InitError)!ArchetypeMeta {
        const tid = try self.type_registry.register(T);
        const cid = try self.comp_registry.register(T, comp_meta);
        const columns = [_]ArchetypeMeta.Column{
            .{ .type_id_val = tid.val, .comp_id_val = cid.val },
        };
        return self.makeMeta(&columns);
    }
};

const TrackedCounter = struct {
    var deinit_count: usize = 0;
    var move_count: usize = 0;

    fn reset() void {
        deinit_count = 0;
        move_count = 0;
    }
};

const Tracked = struct {
    value: u32,

    fn deinit(_: *Tracked) void {
        TrackedCounter.deinit_count += 1;
    }

    fn move(dst: *Tracked, src: *Tracked) void {
        TrackedCounter.move_count += 1;
        dst.* = src.*;
    }

    fn componentMeta() ComponentMeta {
        return ComponentMeta.init(Tracked, .{
            .deinit_fn = deinit,
            .move_fn = move,
        });
    }
};

test "Layout resetCapacity and resetByteLen are consistent" {
    var ctx = ArchetypeChunkTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    const basic = try ctx.registerBasicColumns();
    var meta = try ctx.makeMeta(&basic);
    defer meta.deinit();

    var layout = try ArchetypeChunkTestContext.makeLayout(&meta, 5);
    defer layout.deinit();

    try expectEqual(@as(usize, 5), layout.capacity);
    try expectEqual(@as(usize, @alignOf(EntityId)), layout.buffer_alignment);
    try expectEqual(@as(usize, 0), layout.column_offsets.items[0]);
    try expectEqual(@as(usize, @sizeOf(u64) * 5), layout.column_offsets.items[1]);
    try expectEqual(@as(usize, 64), layout.entity_id_offset);
    try expectEqual(@as(usize, 144), layout.buffer_size);

    const original_len = AlignedBuffer.alignedToOriginal(layout.buffer_size, layout.buffer_alignment);

    var layout2 = try ArchetypeChunk.Layout.init(std.testing.allocator, &meta);
    defer layout2.deinit();

    layout2.resetByteLen(original_len);
    try expectEqual(layout.capacity, layout2.capacity);
    try expectEqual(layout.buffer_size, layout2.buffer_size);
    try expectEqual(layout.entity_id_offset, layout2.entity_id_offset);
    try expectEqual(layout.column_offsets.items[0], layout2.column_offsets.items[0]);
    try expectEqual(layout.column_offsets.items[1], layout2.column_offsets.items[1]);
}

test "ArchetypeChunk push and pop move entity ids and columns" {
    var ctx = ArchetypeChunkTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    const basic = try ctx.registerBasicColumns();
    var meta = try ctx.makeMeta(&basic);
    defer meta.deinit();

    var layout = try ArchetypeChunkTestContext.makeLayout(&meta, 3);
    defer layout.deinit();

    var chunk = try ArchetypeChunk.init(std.testing.allocator, &layout);
    defer chunk.deinit();

    var in_ids = [_]EntityId{
        .{ .val = 10, .generation = 1 },
        .{ .val = 20, .generation = 2 },
        .{ .val = 30, .generation = 3 },
    };
    var in_u64 = [_]u64{ 100, 200, 300 };
    var in_u32 = [_]u32{ 11, 22, 33 };

    var in_cols = [_]ArchetypeChunk.ColumnBuffer{
        ArchetypeChunk.ColumnBuffer.init(u64, in_u64[0..]),
        ArchetypeChunk.ColumnBuffer.init(u32, in_u32[0..]),
    };

    const pushed = chunk.push(in_ids[0..], in_cols[0..]);
    try expectEqual(@as(usize, 3), pushed);
    try expectEqual(@as(usize, 3), chunk.len);

    const ids = chunk.getEntityIds();
    try expectEqual(@as(usize, 10), ids[0].val);
    try expectEqual(@as(usize, 20), ids[1].val);
    try expectEqual(@as(usize, 30), ids[2].val);

    const col0 = chunk.getColumn(0);
    const col1 = chunk.getColumn(1);
    const col0_typed = std.mem.bytesAsSlice(u64, col0.bytes);
    const col1_typed = std.mem.bytesAsSlice(u32, col1.bytes);
    try expectEqual(@as(u64, 100), col0_typed[0]);
    try expectEqual(@as(u64, 200), col0_typed[1]);
    try expectEqual(@as(u64, 300), col0_typed[2]);
    try expectEqual(@as(u32, 11), col1_typed[0]);
    try expectEqual(@as(u32, 22), col1_typed[1]);
    try expectEqual(@as(u32, 33), col1_typed[2]);

    var out_ids = [_]EntityId{ .{}, .{} };
    var out_u64 = [_]u64{ 0, 0 };
    var out_u32 = [_]u32{ 0, 0 };
    var out_cols = [_]?ArchetypeChunk.ColumnBuffer{
        ArchetypeChunk.ColumnBuffer.init(u64, out_u64[0..]),
        ArchetypeChunk.ColumnBuffer.init(u32, out_u32[0..]),
    };

    const popped = chunk.pop(out_ids[0..], out_cols[0..]);
    try expectEqual(@as(usize, 2), popped);
    try expectEqual(@as(usize, 1), chunk.len);

    try expectEqual(@as(usize, 20), out_ids[0].val);
    try expectEqual(@as(usize, 30), out_ids[1].val);
    try expectEqual(@as(u64, 200), out_u64[0]);
    try expectEqual(@as(u64, 300), out_u64[1]);
    try expectEqual(@as(u32, 22), out_u32[0]);
    try expectEqual(@as(u32, 33), out_u32[1]);
}

test "ArchetypeChunk pop supports null column outputs" {
    var ctx = ArchetypeChunkTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    TrackedCounter.reset();

    var meta = try ctx.makeSingleColumnMeta(Tracked, Tracked.componentMeta());
    defer meta.deinit();

    var layout = try ArchetypeChunkTestContext.makeLayout(&meta, 2);
    defer layout.deinit();

    var chunk = try ArchetypeChunk.init(std.testing.allocator, &layout);
    defer chunk.deinit();

    var in_ids = [_]EntityId{
        .{ .val = 1, .generation = 1 },
        .{ .val = 2, .generation = 1 },
    };
    var in_tracked = [_]Tracked{ .{ .value = 7 }, .{ .value = 9 } };
    var in_cols = [_]ArchetypeChunk.ColumnBuffer{ArchetypeChunk.ColumnBuffer.init(Tracked, in_tracked[0..])};

    try expectEqual(@as(usize, 2), chunk.push(in_ids[0..], in_cols[0..]));
    try expectEqual(@as(usize, 2), TrackedCounter.move_count);

    var out_ids = [_]EntityId{.{}};
    var out_cols = [_]?ArchetypeChunk.ColumnBuffer{null};
    const popped = chunk.pop(out_ids[0..], out_cols[0..]);

    try expectEqual(@as(usize, 1), popped);
    try expectEqual(@as(usize, 1), chunk.len);
    try expectEqual(@as(usize, 2), out_ids[0].val);
    try expectEqual(@as(usize, 1), TrackedCounter.deinit_count);
}

test "ArchetypeChunk removeTail runs component deinit" {
    var ctx = ArchetypeChunkTestContext.init(std.testing.allocator);
    defer ctx.deinit();

    TrackedCounter.reset();

    var meta = try ctx.makeSingleColumnMeta(Tracked, Tracked.componentMeta());
    defer meta.deinit();

    var layout = try ArchetypeChunkTestContext.makeLayout(&meta, 3);
    defer layout.deinit();

    var chunk = try ArchetypeChunk.init(std.testing.allocator, &layout);
    defer chunk.deinit();

    var in_ids = [_]EntityId{
        .{ .val = 1, .generation = 1 },
        .{ .val = 2, .generation = 1 },
        .{ .val = 3, .generation = 1 },
    };
    var in_tracked = [_]Tracked{ .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } };
    var in_cols = [_]ArchetypeChunk.ColumnBuffer{ArchetypeChunk.ColumnBuffer.init(Tracked, in_tracked[0..])};

    try expectEqual(@as(usize, 3), chunk.push(in_ids[0..], in_cols[0..]));

    chunk.removeTail(2);
    try expectEqual(@as(usize, 1), chunk.len);
    try expectEqual(@as(usize, 2), TrackedCounter.deinit_count);
}
