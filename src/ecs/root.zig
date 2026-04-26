pub const component = struct {
    const type_registry = @import("component/type_registry.zig");
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

    const data_chunk = @import("entity/data_chunk.zig");
};

test {
    _ = component.type_registry;
    _ = component.component_registry;
    _ = entity.entity_id;
    _ = entity.archetype_meta;
    _ = entity.data_chunk;
}
