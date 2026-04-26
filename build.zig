const std = @import("std");
const ecs = @import("src/ecs/build_mod.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_all_step = b.step("test", "Run all tests");

    const ecs_build_result = ecs.build(b, target, optimize);
    const ecs_mod = ecs_build_result.root_module;
    test_all_step.dependOn(ecs_build_result.test_step);

    const starchor_mod = b.addModule("starchor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = ecs_mod },
        },
    });

    build_examples(b, target, optimize, starchor_mod);
}

fn build_examples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    starchor_mod: *std.Build.Module,
) void {
    inline for ([_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "hello", .path = "examples/hello.zig" },
    }) |example_config| {
        const name = example_config.name;
        const path = example_config.path;

        const prefix_name = std.fmt.allocPrint(b.allocator, "example.{s}", .{name}) catch @panic("OOM");
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
        const build_step_name = std.fmt.allocPrint(b.allocator, "example-{s}", .{name}) catch @panic("OOM");
        const build_step_desc = std.fmt.allocPrint(b.allocator, "Build example: {s}", .{name}) catch @panic("OOM");
        const build_step = b.step(build_step_name, build_step_desc);
        const build_example_cmd = b.addInstallArtifact(example, .{});
        build_step.dependOn(&build_example_cmd.step);

        // Add cmd: zig build run-example-{name}
        const run_step_name = std.fmt.allocPrint(b.allocator, "run-example-{s}", .{name}) catch @panic("OOM");
        const run_step_desc = std.fmt.allocPrint(b.allocator, "Run example: {s}", .{name}) catch @panic("OOM");
        const run_step = b.step(run_step_name, run_step_desc);
        const run_example_cmd = b.addRunArtifact(example);
        run_example_cmd.step.dependOn(&build_example_cmd.step);
        run_step.dependOn(&run_example_cmd.step);
        if (b.args) |args| {
            run_example_cmd.addArgs(args);
        }
    }
}
