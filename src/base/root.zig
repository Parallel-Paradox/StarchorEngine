pub const base = struct {
    pub const mem = struct {
        const aligned_buffer = @import("mem/aligned_buffer.zig");
        pub const AlignedBuffer = aligned_buffer.AlignedBuffer;
    };
};

test {
    _ = base.mem.aligned_buffer;
}
