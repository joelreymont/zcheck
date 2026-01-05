const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const quickcheck_mod = b.createModule(.{
        .root_source_file = b.path("src/quickcheck.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Export the module for dependents
    _ = b.addModule("quickcheck", .{
        .root_source_file = b.path("src/quickcheck.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/quickcheck.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Example executable
    const example_mod = b.createModule(.{
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quickcheck", .module = quickcheck_mod },
        },
    });

    const example = b.addExecutable(.{
        .name = "example",
        .root_module = example_mod,
    });

    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run the example");
    example_step.dependOn(&run_example.step);
}
