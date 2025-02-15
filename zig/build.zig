const std = @import("std");

// Declaratively constructs a build graph that will be executed by an external runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose what target to build
    // for.
    // Here we do not override the defaults, which means any target is allowed, and the default is
    // native.
    // Other options for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select between Debug,
    // ReleaseSafe, ReleaseFast, and ReleaseSmall.
    // Here we do not set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tcp-server-zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the standard location when the
    // user invokes the `install` step (the default step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a build graph step named `run`.
    const run_build_graph_step = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the installation
    // directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed files, this
    // ensures they will be present and in the expected location.
    run_build_graph_step.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build command itself.
    // Like this: `zig build run -- argA argB`.
    if (b.args) |args| {
        run_build_graph_step.addArgs(args);
    }

    // This creates a build step named `run`.
    // It will be visible in the `zig build --help` menu, and can be selected like this:
    //		`zig build run`
    // This will evaluate the `run` step rather than the default, which is `install`.
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_build_graph_step.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_build_graph_step = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_build_graph_step.step);
}
