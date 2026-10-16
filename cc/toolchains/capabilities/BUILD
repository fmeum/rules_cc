load("//cc/toolchains:tool_capability.bzl", "cc_tool_capability")

package(default_visibility = ["//visibility:public"])

cc_tool_capability(
    name = "supports_start_end_lib",
)

# Declares that the tool mapped to the `llvm_cov` action can generate baseline
# coverage, i.e. supports `llvm-cov export -empty-profile` (LLVM 21+).
cc_tool_capability(
    name = "supports_baseline_coverage",
)

cc_tool_capability(
    name = "supports_interface_shared_libraries",
)

cc_tool_capability(
    name = "supports_dynamic_linker",
)

cc_tool_capability(
    name = "supports_pic",
)

cc_tool_capability(
    name = "has_configured_linker_path",
)
