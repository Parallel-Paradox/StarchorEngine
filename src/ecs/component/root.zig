pub const type_registry = @import("type_registry.zig");
pub const component_registry = @import("component_registry.zig");

test {
    _ = type_registry;
    _ = component_registry;
}
