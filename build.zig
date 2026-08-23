const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// Die build.zig zeigt seit 0.61.8 nur noch auf module.R4MF, statt Name,
/// Typ beziehungsweise Rolle und Metadaten ein zweites Mal hinzuschreiben.
/// Damit gibt es hier nichts mehr, was vom Manifest abweichen koennte.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nvme_state.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_state_tests = b.addRunArtifact(state_tests);
    const test_step = b.step("test", "Run deterministic NVMe deadline and recovery-state tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_state_tests.step);
}
