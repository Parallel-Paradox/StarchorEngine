pub const base = @import("base").base;

pub const ecs = struct {
    pub const component = struct {
        const type_registry = @import("component/type_registry.zig");
        pub const TypeAddress = type_registry.TypeAddress;
        pub const TypeId = type_registry.TypeId;
        pub const TypeMeta = type_registry.TypeMeta;
        pub const TypeRegistry = type_registry.TypeRegistry;

        const component_registry = @import("component/component_registry.zig");
        pub const ComponentId = component_registry.ComponentId;
        pub const ComponentMeta = component_registry.ComponentMeta;
        pub const ComponentRegistry = component_registry.ComponentRegistry;
    };

    pub const entity = struct {
        const entity_id = @import("entity/entity_id.zig");
        pub const EntityId = entity_id.EntityId;
        pub const EntitySignature = entity_id.EntitySignature;

        const archetype_meta = @import("entity/archetype_meta.zig");
        pub const ArchetypeSignature = archetype_meta.ArchetypeSignature;
        pub const ArchetypeMeta = archetype_meta.ArchetypeMeta;

        const archetype_chunk = @import("entity/archetype_chunk.zig");
        pub const ArchetypeChunk = archetype_chunk.ArchetypeChunk;

        const archetype = @import("entity/archetype.zig");
        pub const Archetype = archetype.Archetype;
    };
};

test {
    _ = ecs.component.type_registry;
    _ = ecs.component.component_registry;
    _ = ecs.entity.entity_id;
    _ = ecs.entity.archetype_meta;
    _ = ecs.entity.archetype_chunk;
    _ = ecs.entity.archetype;
}
