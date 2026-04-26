const std = @import("std");

pub const BuildResult = struct {
    root_module: *std.Build.Module,
    test_step: *std.Build.Step,
};

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) BuildResult {
    const component_mod = b.createModule(.{
        .root_source_file = b.path("src/ecs/component/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mods = [_]std.Build.Module.Import{
        .{ .name = "component", .module = component_mod },
    };

    const root_module = b.addModule("starchor_ecs", .{
        .root_source_file = b.path("src/ecs/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &mods,
    });

    return BuildResult{
        .root_module = root_module,
        .test_step = build_tests(b, &mods),
    };
}

fn build_tests(b: *std.Build, mods: []const std.Build.Module.Import) *std.Build.Step {
    const test_ecs_step = b.step("test-ecs", "Run tests of module: ecs");

    for (mods) |mod_entry| {
        const name = mod_entry.name;
        const mod = mod_entry.module;

        const prefix_name = std.fmt.allocPrint(b.allocator, "test-ecs-{s}", .{name}) catch @panic("OOM");
        const mod_tests = b.addTest(.{ .name = prefix_name, .root_module = mod });
        const test_mod_cmd = b.addRunArtifact(mod_tests);
        test_ecs_step.dependOn(&test_mod_cmd.step);
    }

    return test_ecs_step;
}
