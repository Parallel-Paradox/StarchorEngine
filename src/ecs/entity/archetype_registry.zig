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
    const ArchetypeList = std.ArrayList(struct { id: ArchetypeId, archetype: Archetype });
    const ArchetypeLookup = std.HashMap(
        // The memory of signature is managed by `ArchetypeMeta`, no need to clone or deinit.
        ArchetypeSignature,
        ArchetypeId,
        ArchetypeSignature.HashContext,
        std.hash_map.default_max_load_percentage,
    );

    allocator: Allocator,
    type_registry: *const TypeRegistry,
    comp_registry: *const ComponentRegistry,
    unused_id: std.ArrayList(ArchetypeId),
    archetypes: ArchetypeList,
    archetype_lookup: ArchetypeLookup,
};
