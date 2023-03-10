const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addStaticLibrary(.{
        .name = "zobench",
        .root_source_file = std.build.FileSource.relative("./src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.install();

    var main_tests = b.addTest(.{
        .root_source_file = std.build.FileSource.relative("./src/main.zig"),
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
