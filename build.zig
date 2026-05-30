const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_git_rev = std.mem.trim(u8, b.run(&.{ "sh", "-c", "git rev-parse HEAD 2>/dev/null || echo unknown" }), " \r\n");
    const default_version = std.mem.trim(u8, b.run(&.{ "sh", "-c", "git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0" }), " \r\n");
    const git_rev = b.option([]const u8, "git-rev", "git commit embedded in the binary") orelse default_git_rev;
    const version = b.option([]const u8, "version", "version embedded in the binary") orelse default_version;

    const options = b.addOptions();
    options.addOption([]const u8, "git_rev", git_rev);
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "zehn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zehn");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/fuzzy.zig", "src/scan.zig", "src/favorites.zig", "src/fork.zig", "src/tui.zig", "src/main.zig" }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addOptions("build_options", options);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
