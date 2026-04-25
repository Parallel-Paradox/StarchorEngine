const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn build(b: *std.Build) Allocator.Error!void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs_mod = b.addModule("starchor_ecs", .{
        .root_source_file = b.path("src/ecs/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mods = [_]std.Build.Module.Import{
        .{ .name = "ecs", .module = ecs_mod },
    };

    const starchor_mod = b.addModule("starchor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &mods,
    });

    try build_tests(b, &mods);
    try build_examples(b, target, optimize, starchor_mod);
}

fn build_tests(b: *std.Build, mods: []const std.Build.Module.Import) Allocator.Error!void {
    const test_all_step = b.step("test", "Run all tests");

    for (mods) |mod_entry| {
        const name = mod_entry.name;
        const mod = mod_entry.module;

        const prefix_name = try std.fmt.allocPrint(b.allocator, "test.{s}", .{name});
        const mod_tests = b.addTest(.{
            .name = prefix_name,
            .root_module = mod,
        });

        const test_step_name = try std.fmt.allocPrint(b.allocator, "test-{s}", .{name});
        const test_step_desc = try std.fmt.allocPrint(b.allocator, "Run tests of module: {s}", .{name});
        const test_step = b.step(test_step_name, test_step_desc);
        const test_mod_cmd = b.addRunArtifact(mod_tests);
        test_step.dependOn(&test_mod_cmd.step);
        test_all_step.dependOn(&test_mod_cmd.step);
    }
}

fn build_examples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    starchor_mod: *std.Build.Module,
) Allocator.Error!void {
    inline for ([_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "hello", .path = "examples/hello.zig" },
    }) |example_config| {
        const name = example_config.name;
        const path = example_config.path;

        const prefix_name = try std.fmt.allocPrint(b.allocator, "example.{s}", .{name});
        const example_mod = b.addModule(prefix_name, .{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "starchor", .module = starchor_mod },
            },
        });

        const example = b.addExecutable(.{
            .name = prefix_name,
            .root_module = example_mod,
        });

        // Add cmd: zig build example-{name}
        const build_step_name = try std.fmt.allocPrint(b.allocator, "example-{s}", .{name});
        const build_step_desc = try std.fmt.allocPrint(b.allocator, "Build example: {s}", .{name});
        const build_step = b.step(build_step_name, build_step_desc);
        const build_example_cmd = b.addInstallArtifact(example, .{});
        build_step.dependOn(&build_example_cmd.step);

        // Add cmd: zig build run-example-{name}
        const run_step_name = try std.fmt.allocPrint(b.allocator, "run-example-{s}", .{name});
        const run_step_desc = try std.fmt.allocPrint(b.allocator, "Run example: {s}", .{name});
        const run_step = b.step(run_step_name, run_step_desc);
        const run_example_cmd = b.addRunArtifact(example);
        run_example_cmd.step.dependOn(&build_example_cmd.step);
        run_step.dependOn(&run_example_cmd.step);
        if (b.args) |args| {
            run_example_cmd.addArgs(args);
        }
    }
}
