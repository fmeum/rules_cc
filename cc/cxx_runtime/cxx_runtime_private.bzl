# Copyright 2026 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""The C++ runtime that C++ toolchains should link against."""

load("@platforms_contrib//os/linux/libc:libc.bzl", "PreferredLibcInfo")
load("@platforms_contrib//os/windows/crt:crt.bzl", "PreferredWindowsCrtInfo")
load("//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_ATTRS", "find_cpp_toolchain", "use_cc_toolchain")
load("//cc/common:cc_common.bzl", "cc_common")
load("//cc/common:feature_names.bzl", "feature_names")
load(":cxx_runtime.bzl", "PreferredCxxRuntimeInfo", "check_preferred_cxx_runtime")

visibility(["//cc/cxx_runtime", "//cc/private/link", "//tests/cc/cxx_runtime"])

CXX_RUNTIME_FLAVORS = [
    "libc++",
    "libstdc++",
    "msvcp",
]

CXX_RUNTIME_LINKAGES = [
    "bundled",
    "static",
    "system",
]

_PREFIXES = {
    "bundled": "bundled-",
    "static": "static-",
}

_NONE = "none"

# The values of //cc/cxx_runtime:preference.
CXX_RUNTIME_PREFERENCES = CXX_RUNTIME_FLAVORS + [
    prefix + flavor
    for prefix in _PREFIXES.values()
    for flavor in CXX_RUNTIME_FLAVORS
] + [_NONE]

_CxxRuntimePreferenceInfo = provider(
    doc = "The ranking of C++ runtime options set via //cc/cxx_runtime:preference.",
    fields = ["preferences"],
)

def _cxx_runtime_preference_flag_impl(ctx):
    for preference in ctx.build_setting_value:
        if preference not in CXX_RUNTIME_PREFERENCES:
            fail("Unsupported C++ runtime preference {preference} in --{flag}, expected one of: {supported}".format(
                preference = repr(preference),
                flag = ctx.label,
                supported = ", ".join([repr(supported) for supported in CXX_RUNTIME_PREFERENCES]),
            ))
    return [_CxxRuntimePreferenceInfo(preferences = ctx.build_setting_value)]

cxx_runtime_preference_flag = rule(
    implementation = _cxx_runtime_preference_flag_impl,
    build_setting = config.string_list(flag = True),
    attrs = {
        # Read by Bazel 9 and later to decide whether the value propagates to exec configurations.
        "scope": attr.string(),
    },
)

def _parse(preference):
    if preference == _NONE:
        return _NONE, _NONE
    for linkage, prefix in _PREFIXES.items():
        if preference.startswith(prefix):
            return linkage, preference.removeprefix(prefix)
    return "system", preference

def _has(ctx, constraint_value):
    return ctx.target_platform_has_constraint(constraint_value[platform_common.ConstraintValueInfo])

def _no_libc(ctx):
    return (ctx.attr._preferred_libc[PreferredLibcInfo].flavor == _NONE or
            ctx.attr._preferred_crt[PreferredWindowsCrtInfo].flavor == _NONE)

def _links_libc_statically(ctx):
    preferred_libc = ctx.attr._preferred_libc[PreferredLibcInfo]
    if preferred_libc.status == "resolved":
        return preferred_libc.requires_fully_static
    preferred_crt = ctx.attr._preferred_crt[PreferredWindowsCrtInfo]
    if preferred_crt.status == "resolved":
        return preferred_crt.requires_static
    return False

def _reject_reason(ctx, linkage, flavor, libc_static, no_libc):
    """Returns why an option isn't viable for the target platform or None if it is."""
    if linkage == _NONE:
        return None
    if no_libc:
        return "a C++ runtime can't be used without a libc"
    windows = _has(ctx, ctx.attr._windows)
    macos = _has(ctx, ctx.attr._macos)
    if flavor == "msvcp" and not windows:
        return "msvcp only exists on Windows"
    if flavor == "libstdc++" and macos:
        return "libstdc++ isn't available for macOS"
    if linkage == "static":
        return None
    if libc_static:
        return "a statically linked libc can't be combined with a shared C++ runtime"
    if linkage == "bundled":
        return None
    if macos:
        # libSystem and libc++ are part of every macOS version.
        return None if flavor == "libc++" else "macOS only provides libc++"
    available = {
        "libc++": ctx.attr._libcxx_available,
        "libstdc++": ctx.attr._libstdcxx_available,
        "msvcp": ctx.attr._msvcp_available,
    }[flavor]
    if not _has(ctx, available):
        return "the platform doesn't declare {} as available via {}".format(flavor, available.label)
    return None

def _resolve(ctx):
    """Returns the PreferredCxxRuntimeInfo for the target platform.

    This must never fail for valid rankings since registered toolchains that use the config settings
    derived from it in their `target_settings` are configured for every target platform.
    """
    preferences = ctx.attr._preference[_CxxRuntimePreferenceInfo].preferences
    no_libc = _no_libc(ctx)
    if not preferences:
        if no_libc:
            return PreferredCxxRuntimeInfo(status = "resolved", flavor = _NONE, linkage = _NONE, diagnostic = "")
        return PreferredCxxRuntimeInfo(status = "unset", flavor = None, linkage = None, diagnostic = "")

    libc_static = _links_libc_statically(ctx)
    reasons = []
    for preference in preferences:
        linkage, flavor = _parse(preference)
        reason = _reject_reason(ctx, linkage, flavor, libc_static, no_libc)
        if reason == None:
            return PreferredCxxRuntimeInfo(status = "resolved", flavor = flavor, linkage = linkage, diagnostic = "")
        reasons.append("{}: {}".format(preference, reason))

    return PreferredCxxRuntimeInfo(
        status = "unresolved",
        flavor = None,
        linkage = None,
        diagnostic = "None of the C++ runtime options in --@rules_cc//cc/cxx_runtime:preference={preferences} is viable for the target platform {platform} ({reasons}). {remedy}".format(
            preferences = ",".join(preferences),
            platform = ctx.fragments.platform.platform,
            reasons = "; ".join(reasons),
            remedy = "Rank \"none\" or leave the ranking empty." if no_libc else "Declare the runtime on the platform or rank a \"bundled-\" or \"static-\" option.",
        ),
    )

def _preferred_cxx_runtime_impl(ctx):
    preferred = _resolve(ctx)
    if preferred.status != "resolved":
        flag_value = preferred.status
    elif ctx.attr.provide_linkage:
        flag_value = preferred.linkage
    else:
        flag_value = preferred.flavor
    return [
        preferred,
        config_common.FeatureFlagInfo(value = flag_value),
        platform_common.TemplateVariableInfo({
            "PREFERRED_CXX_RUNTIME": preferred.flavor or "",
            "PREFERRED_CXX_RUNTIME_LINKAGE": preferred.linkage or "",
            "PREFERRED_CXX_RUNTIME_STATUS": preferred.status,
        }),
    ]

preferred_cxx_runtime = rule(
    implementation = _preferred_cxx_runtime_impl,
    attrs = {
        "provide_linkage": attr.bool(
            doc = "Whether to provide the linkage instead of the flavor for " +
                  "`config_setting.flag_values`.",
        ),
        "_libcxx_available": attr.label(default = "@platforms_contrib//os/linux/cxx_runtime/libcxx:available"),
        "_libstdcxx_available": attr.label(default = "@platforms_contrib//os/linux/cxx_runtime/libstdcxx:available"),
        "_macos": attr.label(default = "@platforms//os:macos"),
        "_msvcp_available": attr.label(default = "@platforms_contrib//os/windows/cxx_runtime/msvcp:available"),
        "_preference": attr.label(default = ":preference"),
        "_preferred_crt": attr.label(default = "@platforms_contrib//os/windows/crt:preferred"),
        "_preferred_libc": attr.label(default = "@platforms_contrib//os/linux/libc:preferred"),
        "_windows": attr.label(default = "@platforms//os:windows"),
    },
    fragments = ["platform"],
)

def _validate_preferred_cxx_runtime_impl(ctx):
    check_preferred_cxx_runtime(ctx.attr._preferred[PreferredCxxRuntimeInfo])
    return []

validate_preferred_cxx_runtime = rule(
    implementation = _validate_preferred_cxx_runtime_impl,
    attrs = {
        "_preferred": attr.label(default = ":preferred"),
    },
)

def _cxx_runtime_linkage_flag_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    if feature_configuration.is_enabled(feature_names.STATIC_CXX_RUNTIME):
        value = "static"
    elif feature_configuration.is_enabled(feature_names.DYNAMIC_CXX_RUNTIME):
        value = "dynamic"
    else:
        value = "unknown"
    return [config_common.FeatureFlagInfo(value = value)]

cxx_runtime_linkage_flag = rule(
    implementation = _cxx_runtime_linkage_flag_impl,
    attrs = CC_TOOLCHAIN_ATTRS,
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
