# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Implementation of the cc_toolchain rule."""

load("//cc/common:cc_common.bzl", "cc_common")
load(
    "//cc/private/rules_impl:cc_toolchain_provider_helper.bzl",
    "get_cc_toolchain_provider",
)
load(
    "//cc/toolchains:cc_toolchain_info.bzl",
    "ActionTypeSetInfo",
    "ArgsListInfo",
    "ArtifactNamePatternInfo",
    "FeatureSetInfo",
    "MakeVariableInfo",
    "ToolConfigInfo",
    "ToolchainConfigInfo",
)
load(":collect.bzl", "collect_action_types")
load(":legacy_converter.bzl", "convert_toolchain")
load(":toolchain_config_info.bzl", "toolchain_config_info")

visibility([
    "//cc/toolchains/...",
    "//tests/rule_based_toolchain/...",
])

# Taken from https://bazel.build/docs/cc-toolchain-config-reference#actions
# TODO: This is best-effort. Update this with the correct file groups once we
#  work out what actions correspond to what file groups.
_LEGACY_FILE_GROUPS = {
    "ar_files": [
        Label("//cc/toolchains/actions:ar_actions"),
    ],
    "as_files": [
        Label("//cc/toolchains/actions:assembly_actions"),
    ],
    "compiler_files": [
        Label("//cc/toolchains/actions:cc_flags_make_variable"),
        Label("//cc/toolchains/actions:c_compile"),
        Label("//cc/toolchains/actions:cpp_compile"),
        Label("//cc/toolchains/actions:cpp_header_parsing"),
    ],
    # There are no actions listed for coverage and objcopy in action_names.bzl.
    "coverage_files": [],
    "dwp_files": [
        Label("//cc/toolchains/actions:dwp"),
    ],
    "linker_files": [
        Label("//cc/toolchains/actions:cpp_link_dynamic_library"),
        Label("//cc/toolchains/actions:cpp_link_nodeps_dynamic_library"),
        Label("//cc/toolchains/actions:cpp_link_executable"),
    ],
    "objcopy_files": [],
    "strip_files": [
        Label("//cc/toolchains/actions:strip"),
    ],
}

def _cc_legacy_file_group_impl(ctx):
    files = ctx.attr.config[ToolchainConfigInfo].files

    return [DefaultInfo(files = depset(transitive = [
        files[action]
        for action in collect_action_types(ctx.attr.actions).to_list()
        if action in files
    ]))]

cc_legacy_file_group = rule(
    implementation = _cc_legacy_file_group_impl,
    attrs = {
        "actions": attr.label_list(providers = [ActionTypeSetInfo], mandatory = True),
        "config": attr.label(providers = [ToolchainConfigInfo], mandatory = True),
    },
)

def _attributes(ctx):
    grep_includes = None
    if not semantics.is_bazel:
        grep_includes = ctx.file._grep_includes

    latebound_libc = _latebound_libc(ctx, "libc_top", "_libc_top")

    all_files = _files(ctx, "all_files")
    return struct(
        supports_param_files = ctx.attr.supports_param_files,
        runtime_solib_dir_base = "_solib__" + cc_common.escape_label(label = ctx.label),
        cc_toolchain_config_info = _provider(ctx.attr.toolchain_config, CcToolchainConfigInfo),
        static_runtime_lib = ctx.attr.static_runtime_lib,
        dynamic_runtime_lib = ctx.attr.dynamic_runtime_lib,
        supports_header_parsing = ctx.attr.supports_header_parsing,
        all_files = all_files,
        compiler_files = _files(ctx, "compiler_files"),
        strip_files = _files(ctx, "strip_files"),
        objcopy_files = _files(ctx, "objcopy_files"),
        link_dynamic_library_tool = ctx.file._link_dynamic_library_tool,
        grep_includes = grep_includes,
        aggregate_ddi = _single_file(ctx, "_aggregate_ddi"),
        generate_modmap = _single_file(ctx, "_generate_modmap"),
        module_map = ctx.attr.module_map,
        as_files = _files(ctx, "as_files"),
        ar_files = _files(ctx, "ar_files"),
        dwp_files = _files(ctx, "dwp_files"),
        module_map_artifact = _single_file(ctx, "module_map"),
        all_files_including_libc = depset(transitive = [_files(ctx, "all_files"), _files(ctx, latebound_libc)]),
        zipper = ctx.file._zipper,
        linker_files = _full_inputs_for_link(
            ctx,
            _files(ctx, "linker_files"),
            _files(ctx, latebound_libc),
        ),
        cc_toolchain_label = ctx.label,
        coverage_files = _files(ctx, "coverage_files") or all_files,
        compiler_files_without_includes = _files(ctx, "compiler_files_without_includes"),
        libc = _files(ctx, latebound_libc),
        libc_top_label = _label(ctx, latebound_libc),
        if_so_builder = ctx.file._interface_library_builder,
        allowlist_for_layering_check = _package_specification_provider(ctx, "disabling_parse_headers_and_layering_check_allowed"),
        build_info_files = _provider(ctx.attr._build_info_translator, OutputGroupInfo),
    )

def _cc_toolchain_impl(ctx):
    if ctx.attr.features:
        fail("Features is a reserved attribute in bazel. Did you mean 'known_features' or 'enabled_features'?")

    toolchain_config = toolchain_config_info(
        label = ctx.label,
        known_features = ctx.attr.known_features + [ctx.attr._builtin_features],
        enabled_features = ctx.attr.enabled_features,
        tool_map = ctx.attr.tool_map,
        args = ctx.attr.args,
        artifact_name_patterns = ctx.attr.artifact_name_patterns,
        make_variables = ctx.attr.make_variables,
    )

    legacy = convert_toolchain(toolchain_config)

    cc_toolchain_config_info = cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        action_configs = legacy.action_configs,
        artifact_name_patterns = legacy.artifact_name_patterns,
        make_variables = legacy.make_variables,
        features = legacy.features,
        cxx_builtin_include_directories = legacy.cxx_builtin_include_directories,
        # toolchain_identifier is deprecated, but setting it to None results
        # in an error that it expected a string, and for safety's sake, I'd
        # prefer to provide something unique.
        toolchain_identifier = str(ctx.label),
        # This can be accessed by users through
        # @rules_cc//cc/private/toolchain:compiler to select() on the current
        # compiler
        compiler = ctx.attr.compiler,
        target_cpu = ctx.attr.cpu,
        # These fields are only relevant for legacy toolchain resolution.
        target_system_name = "",
        target_libc = "",
        abi_version = "",
        abi_libc_version = "",
    )

    cc_toolchain = get_cc_toolchain_provider(ctx, attributes)
    if cc_toolchain == None:
        fail("This should never happen")
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    template_vars = cc_toolchain._additional_make_variables | cc_helper.get_toolchain_global_make_variables(cc_toolchain) | cc_helper.get_cc_flags_make_variable(ctx, feature_configuration, cc_toolchain)
    template_variable_info = TemplateVariableInfo(template_vars)
    toolchain = ToolchainInfo(
        cc = cc_toolchain,
        # Add a clear signal that this is a CcToolchainProvider, since just "cc" is
        # generic enough to possibly be re-used.
        cc_provider_in_toolchain = True,
    )
    return [
        cc_toolchain,
        toolchain,
        template_variable_info,
        DefaultInfo(
            files = cc_toolchain._all_files_including_libc,
        ),
    ]

def _cc_toolchain_initializer(**kwargs):
    return {
        cpu: select({
            Label("//cc/toolchains/impl:darwin_aarch64"): "darwin_arm64",
            Label("//cc/toolchains/impl:darwin_x86_64"): "darwin_x86_64",
            Label("//cc/toolchains/impl:linux_aarch64"): "aarch64",
            Label("//cc/toolchains/impl:linux_x86_64"): "k8",
            Label("//cc/toolchains/impl:windows_x86_32"): "win32",
            Label("//cc/toolchains/impl:windows_x86_64"): "win64",
            "//conditions:default": "",
        }),
    } | kwargs

cc_toolchain = rule(
    implementation = _cc_toolchain_impl,
    initializer = _cc_toolchain_initializer,
    # @unsorted-dict-items
    attrs = {
        "compiler": attr.string(default = ""),
        "cpu": attr.string(default = ""),
        "tool_map": attr.label(
            cfg = "exec",
            providers = [ToolConfigInfo],
            mandatory = True,
        ),
        "args": attr.label_list(providers = [ArgsListInfo]),
        "known_features": attr.label_list(providers = [FeatureSetInfo]),
        "enabled_features": attr.label_list(providers = [FeatureSetInfo]),
        "artifact_name_patterns": attr.label_list(providers = [ArtifactNamePatternInfo]),
        "make_variables": attr.label_list(providers = [MakeVariableInfo]),
        "_builtin_features": attr.label(default = "//cc/toolchains/features:all_builtin_features"),
    },
    provides = [ToolchainConfigInfo],
)
