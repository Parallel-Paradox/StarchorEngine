const std = @import("std");

pub const EntityId = struct {
    pub const INVALID_ID: usize = std.math.maxInt(usize);
    pub const TOMB_GENERATION: usize = std.math.maxInt(usize);

    val: usize = INVALID_ID,
    generation: usize = TOMB_GENERATION,

    pub fn equal(self: @This(), other: @This()) bool {
        return self.val == other.val and self.generation == other.generation;
    }
};

const expectEqual = std.testing.expectEqual;

test "EntityId default is tombstone sentinel" {
    const id = EntityId{};
    try expectEqual(EntityId.INVALID_ID, id.val);
    try expectEqual(EntityId.TOMB_GENERATION, id.generation);
}
