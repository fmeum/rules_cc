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
"""Keeps the libc and C++ runtime preferences consistent with C++ features and link modes.

The preferences hold for an entire configuration. They reach toolchains, rules and other languages
as ordinary features that `configure_features` requests, so this file is the only place that
interprets them. There are three layers:

  * `linkage_error` runs once per toolchain and configuration. It determines whether the toolchain
    can't deliver a preference or a global flag contradicts it. Rules that configure features for
    such a toolchain fail with this error, but the toolchain itself doesn't, as Bazel would
    report that as a toolchain resolution error for everything that depends on it.
  * `reconcile_linkage_features` and `check_linkage_features` run for every feature configuration.
    They turn the preferences into features, apply per-target overrides that only affect the link and
    fail for all others.
  * `links_cxx_runtime_statically`, `requires_static_linking_mode` and the `check_*` functions below
    run for every link.

If all preferences are at their default values, none of this has any effect and the C++ runtime is
linked the same way as the libraries of the binary.
"""

load("//cc/common:feature_names.bzl", "feature_names")
load("//cc/private/link:target_types.bzl", "LINKING_MODE")
load("//cc/toolchains/impl:libc_version.bzl", "libc_without_version")

_LIBC_FLAG = "--@platforms_contrib//os/linux/libc:preference"
_CRT_FLAG = "--@platforms_contrib//os/windows/crt:preference"
_CXX_RUNTIME_FLAG = "--@rules_cc//cc/cxx_runtime:preference"

_FLAVOR_FEATURES = {
    "libc++": feature_names.LIBCXX_RUNTIME,
    "libstdc++": feature_names.LIBSTDCXX_RUNTIME,
    "msvcp": feature_names.MSVCP_RUNTIME,
}

# The libc flavors that toolchains report via `target_libc` and that preferences can select.
_PREFERABLE_LIBCS = ["glibc", "musl", "ucrt", "msvcrt"]

_NONE = "none"

LinkageChoicesInfo = provider(
    doc = "The libc, CRT and C++ runtime preferences resolved against the target platform.",
    fields = {
        "cxx_runtime": "The PreferredCxxRuntimeInfo.",
        "fully_static": "Whether a libc preference requires all executables to be fully static.",
        "libc_flavor": "The preferred libc or CRT flavor, \"none\" for no libc, or None if there " +
                       "is no preference.",
        "requested_features": "The features that represent the preferences. A toolchain has to " +
                              "define the ones in `required_features`.",
        "required_features": "A dict from feature to the flag that makes the toolchain require it.",
        "static_crt": "Whether a CRT preference requires a static (True) or dynamic (False) CRT, " +
                      "or None if there is no CRT preference.",
        "unsupported_features": "The features that contradict the preferences.",
        "windows": "Whether the target platform is Windows.",
    },
)

def create_linkage_choices(*, windows, preferred_libc, preferred_crt, cxx_runtime):
    """Creates the LinkageChoicesInfo for the given resolved preferences.

    Args:
      windows: Whether the target platform is Windows.
      preferred_libc: The PreferredLibcInfo.
      preferred_crt: The PreferredWindowsCrtInfo.
      cxx_runtime: The PreferredCxxRuntimeInfo.

    Returns:
      The LinkageChoicesInfo.
    """
    fully_static = preferred_libc.status == "resolved" and preferred_libc.requires_fully_static
    static_crt = preferred_crt.requires_static if preferred_crt.status == "resolved" else None
    if preferred_libc.status == "resolved":
        libc_flavor = preferred_libc.flavor
    elif preferred_crt.status == "resolved":
        libc_flavor = preferred_crt.flavor
    else:
        libc_flavor = None

    required = {}
    requested = []
    unsupported = []
    libc_flag = _CRT_FLAG if windows else _LIBC_FLAG
    no_libc = libc_flavor == _NONE

    if fully_static:
        required[feature_names.FULLY_STATIC_LINK] = _LIBC_FLAG

    if no_libc:
        required[feature_names.NO_LIBC] = libc_flag

    if cxx_runtime.status == "resolved":
        if cxx_runtime.linkage == _NONE:
            required[feature_names.NO_CXX_RUNTIME] = libc_flag if no_libc else _CXX_RUNTIME_FLAG
            unsupported.append(feature_names.STATIC_CXX_RUNTIME)
            unsupported.append(feature_names.DYNAMIC_CXX_RUNTIME)
        elif cxx_runtime.linkage == "static":
            required[feature_names.STATIC_CXX_RUNTIME] = _CXX_RUNTIME_FLAG
            unsupported.append(feature_names.DYNAMIC_CXX_RUNTIME)
        else:
            required[feature_names.DYNAMIC_CXX_RUNTIME] = _CXX_RUNTIME_FLAG
            required[feature_names.SYSTEM_CXX_RUNTIME if cxx_runtime.linkage == "system" else feature_names.BUNDLED_CXX_RUNTIME] = _CXX_RUNTIME_FLAG
            unsupported.append(feature_names.STATIC_CXX_RUNTIME)
            unsupported.append(feature_names.STATIC_LIBGCC)
        if cxx_runtime.linkage != _NONE:
            required[_FLAVOR_FEATURES[cxx_runtime.flavor]] = _CXX_RUNTIME_FLAG

    if windows:
        static_msvcp = cxx_runtime.status == "resolved" and cxx_runtime.flavor == "msvcp" and cxx_runtime.linkage == "static"
        if no_libc:
            unsupported.append(feature_names.STATIC_LINK_MSVCRT)
            unsupported.append(feature_names.DYNAMIC_LINK_MSVCRT)
        elif static_crt or static_msvcp:
            # /MT selects the static C++ runtime and, unless the UCRT is replaced at link time, the
            # static UCRT.
            required[feature_names.STATIC_LINK_MSVCRT] = _CRT_FLAG if static_crt else _CXX_RUNTIME_FLAG
            unsupported.append(feature_names.DYNAMIC_LINK_MSVCRT)
            if static_crt == False:
                required[feature_names.HYBRID_CRT] = _CXX_RUNTIME_FLAG
        elif static_crt == False or (cxx_runtime.status == "resolved" and cxx_runtime.flavor == "msvcp"):
            # MinGW toolchains always link the CRT dynamically, so they don't have to define this.
            requested.append(feature_names.DYNAMIC_LINK_MSVCRT)
            unsupported.append(feature_names.STATIC_LINK_MSVCRT)

    return LinkageChoicesInfo(
        cxx_runtime = cxx_runtime,
        fully_static = fully_static,
        libc_flavor = libc_flavor,
        requested_features = requested + required.keys(),
        required_features = required,
        static_crt = static_crt,
        unsupported_features = unsupported,
        windows = windows,
    )

def linkage_error(*, choices, toolchain_features, toolchain_label, target_libc, cpp_configuration):
    """Returns why the toolchain can't deliver the preferences or None if it can.

    Args:
      choices: The LinkageChoicesInfo.
      toolchain_features: The CcToolchainFeatures of the toolchain.
      toolchain_label: The label of the toolchain.
      target_libc: The target_libc of the toolchain.
      cpp_configuration: The cpp configuration fragment.

    Returns:
      An error message or None.
    """
    if choices.cxx_runtime.status == "unresolved":
        return choices.cxx_runtime.diagnostic

    for feature, flag in choices.required_features.items():
        if not toolchain_features.configure_features(requested_features = [feature]).is_enabled(feature):
            return ("The C++ toolchain '{toolchain}' can't deliver the choice made by {flag} since " +
                    "it doesn't define the feature '{feature}'. Choose an option it supports or " +
                    "use a different toolchain.").format(
                toolchain = toolchain_label,
                flag = flag,
                feature = feature,
            )

    toolchain_libc = libc_without_version(target_libc)
    if choices.libc_flavor in _PREFERABLE_LIBCS and toolchain_libc in _PREFERABLE_LIBCS and choices.libc_flavor != toolchain_libc:
        return ("The C++ toolchain '{toolchain}' targets {toolchain_libc}, but {flag} chose {libc}. " +
                "Toolchains should use the corresponding config settings in their " +
                "target_settings.").format(
            toolchain = toolchain_label,
            toolchain_libc = toolchain_libc,
            flag = _CRT_FLAG if choices.windows else _LIBC_FLAG,
            libc = choices.libc_flavor,
        )

    if cpp_configuration.dynamic_mode() == "FULLY":
        if choices.fully_static:
            return "--dynamic_mode=fully conflicts with {}, which requires fully static binaries.".format(_LIBC_FLAG)
        if choices.cxx_runtime.linkage == "static" and not choices.windows:
            return "--dynamic_mode=fully conflicts with {}, which requires a static C++ runtime.".format(_CXX_RUNTIME_FLAG)

    return None

def reconcile_linkage_features(*, choices, default_features, requested_features, unsupported_features):
    """Returns the features to request and to mark as unsupported to follow the preferences.

    Targets can override how the C++ runtime is linked where that only affects their own link, which
    is the case on all platforms but Windows. All other conflicts fail.

    Args:
      choices: The LinkageChoicesInfo.
      default_features: The features the toolchain enables by default.
      requested_features: The features requested by the rule, the target and on the command line.
      unsupported_features: The features disabled by the rule, the target and on the command line.

    Returns:
      A tuple of the list of features to additionally request and the set of features to
      additionally treat as unsupported.
    """
    requested = list(choices.requested_features)
    unsupported = set(choices.unsupported_features)

    for feature, flag in choices.required_features.items():
        if feature in unsupported_features:
            fail("Disabling the feature '{}' conflicts with {}.".format(feature, flag))

    for feature in (feature_names.STATIC_LINK_MSVCRT, feature_names.DYNAMIC_LINK_MSVCRT):
        if feature in unsupported and feature in requested_features:
            fail(("The feature '{}' conflicts with {}. The CRT affects compilation and thus has to " +
                  "be the same for the entire build.").format(feature, _CRT_FLAG))

    if feature_names.NO_LIBC in requested_features and choices.libc_flavor not in (None, _NONE):
        fail(("The feature '{}' conflicts with {}, which chose {}. The libc affects compilation and " +
              "thus has to be the same for a target and its dependencies, so use a transition to " +
              "change the preference.").format(
            feature_names.NO_LIBC,
            _CRT_FLAG if choices.windows else _LIBC_FLAG,
            choices.libc_flavor,
        ))

    if (feature_names.NO_CXX_RUNTIME in requested_features and
        choices.cxx_runtime.status == "resolved" and
        choices.cxx_runtime.linkage != _NONE):
        fail(("The feature '{}' conflicts with {}. The C++ runtime headers affect compilation and " +
              "thus have to be the same for a target and its dependencies, so use a transition to " +
              "change the preference.").format(feature_names.NO_CXX_RUNTIME, _CXX_RUNTIME_FLAG))

    if choices.cxx_runtime.linkage == _NONE:
        for feature in (feature_names.STATIC_CXX_RUNTIME, feature_names.DYNAMIC_CXX_RUNTIME):
            if feature in requested_features:
                fail("The feature '{}' conflicts with the choice of no C++ runtime.".format(feature))

    wants_static_cxx_runtime = choices.cxx_runtime.linkage == "static"
    if wants_static_cxx_runtime and feature_names.DYNAMIC_CXX_RUNTIME in requested_features:
        if choices.fully_static:
            fail("The feature '{}' conflicts with {}, which requires a static C++ runtime.".format(
                feature_names.DYNAMIC_CXX_RUNTIME,
                _LIBC_FLAG,
            ))
        _fail_if_cxx_runtime_is_graph_wide(choices, feature_names.DYNAMIC_CXX_RUNTIME)
        wants_static_cxx_runtime = False
        requested.remove(feature_names.STATIC_CXX_RUNTIME)
        unsupported.remove(feature_names.DYNAMIC_CXX_RUNTIME)
        unsupported.add(feature_names.STATIC_CXX_RUNTIME)
        unsupported.add(feature_names.STATIC_LIBGCC)
    elif choices.cxx_runtime.linkage in ("system", "bundled") and (
        feature_names.STATIC_CXX_RUNTIME in requested_features or
        feature_names.FULLY_STATIC_LINK in requested_features or
        feature_names.FULLY_STATIC_LINK in default_features
    ):
        _fail_if_cxx_runtime_is_graph_wide(choices, feature_names.STATIC_CXX_RUNTIME)
        wants_static_cxx_runtime = True
        requested = [
            feature
            for feature in requested
            if feature not in (feature_names.DYNAMIC_CXX_RUNTIME, feature_names.SYSTEM_CXX_RUNTIME, feature_names.BUNDLED_CXX_RUNTIME)
        ] + [feature_names.STATIC_CXX_RUNTIME]
        unsupported.remove(feature_names.STATIC_CXX_RUNTIME)
        unsupported.remove(feature_names.STATIC_LIBGCC)
        unsupported.add(feature_names.DYNAMIC_CXX_RUNTIME)

    # With a static C++ runtime, the implicit shared objects of cc_library would have undefined
    # symbols or their own copies of the runtime. cc_shared_library remains an explicit choice and
    # DLLs bring their own runtimes by design.
    if not choices.windows and (choices.fully_static or wants_static_cxx_runtime or feature_names.STATIC_CXX_RUNTIME in requested_features):
        unsupported.add(feature_names.SUPPORTS_DYNAMIC_LINKER)

    return requested, unsupported

def _fail_if_cxx_runtime_is_graph_wide(choices, feature):
    if choices.windows:
        fail(("The feature '{}' conflicts with {}. The C++ runtime affects compilation on Windows " +
              "and thus has to be the same for the entire build.").format(feature, _CXX_RUNTIME_FLAG))

def check_linkage_features(*, cc_toolchain, feature_configuration):
    """Fails if a toolchain enables features that contradict each other.

    Args:
      cc_toolchain: The CcToolchainInfo.
      feature_configuration: The feature configuration.
    """
    if not feature_configuration.is_enabled(feature_names.DYNAMIC_CXX_RUNTIME):
        return
    if feature_configuration.is_enabled(feature_names.STATIC_CXX_RUNTIME):
        fail("The C++ toolchain '{}' enables both '{}' and '{}'.".format(
            cc_toolchain._toolchain_label,
            feature_names.STATIC_CXX_RUNTIME,
            feature_names.DYNAMIC_CXX_RUNTIME,
        ))
    if feature_configuration.is_enabled(feature_names.FULLY_STATIC_LINK):
        fail("The C++ toolchain '{}' enables both '{}' and '{}', but a fully static binary can't use a shared C++ runtime.".format(
            cc_toolchain._toolchain_label,
            feature_names.FULLY_STATIC_LINK,
            feature_names.DYNAMIC_CXX_RUNTIME,
        ))

def requires_static_linking_mode(feature_configuration):
    """Returns whether all libraries of a link have to be linked statically if possible.

    Args:
      feature_configuration: The feature configuration.

    Returns:
      Whether the link mode has to be static, regardless of `linkstatic` and `--dynamic_mode`.
    """
    if feature_configuration.is_enabled(feature_names.FULLY_STATIC_LINK):
        return True
    return (feature_configuration.is_enabled(feature_names.STATIC_CXX_RUNTIME) and
            not feature_configuration.is_enabled(feature_names.TARGETS_WINDOWS))

def links_cxx_runtime_statically(feature_configuration, linking_mode):
    """Returns whether a link uses the static instead of the dynamic runtime libraries of the toolchain.

    Args:
      feature_configuration: The feature configuration.
      linking_mode: The LINKING_MODE of the link.

    Returns:
      Whether the static runtime libraries should be linked.
    """
    if (feature_configuration.is_enabled(feature_names.FULLY_STATIC_LINK) or
        feature_configuration.is_enabled(feature_names.STATIC_LINK_MSVCRT) or
        feature_configuration.is_enabled(feature_names.STATIC_CXX_RUNTIME)):
        return True
    if feature_configuration.is_enabled(feature_names.DYNAMIC_CXX_RUNTIME):
        return False
    return linking_mode != LINKING_MODE.DYNAMIC

def check_can_link_shared_library(*, cc_toolchain, name):
    """Fails if shared libraries can't be used with the preferences.

    Args:
      cc_toolchain: The CcToolchainInfo.
      name: The name of the shared library.
    """
    # A shared library without a libc can still be loaded by a host with its own loader.
    if cc_toolchain._linkage_choices.fully_static and cc_toolchain._linkage_choices.libc_flavor != _NONE:
        fail(("The shared library '{}' can't be linked since {} requires fully static binaries, " +
              "which can't load shared libraries. Rank an option without the \"static-\" prefix " +
              "or add @platforms_contrib//os/linux/libc:requires_fully_static to the " +
              "target_compatible_with of the target to skip it.").format(name, _LIBC_FLAG))

def check_fully_static_inputs(*, feature_configuration, output, libraries_to_link, prefer_static_libs):
    """Fails if a fully static executable depends on libraries that only exist as shared libraries.

    Args:
      feature_configuration: The feature configuration.
      output: The File of the executable.
      libraries_to_link: The list of LibraryToLink.
      prefer_static_libs: Whether static libraries are preferred for this link.
    """
    if (not feature_configuration.is_enabled(feature_names.FULLY_STATIC_LINK) or
        feature_configuration.is_enabled(feature_names.TARGETS_WINDOWS)):
        return
    shared_libraries = [
        (library.dynamic_library or library.interface_library).short_path
        for library in libraries_to_link
        if (library.dynamic_library or library.interface_library) and not (
            prefer_static_libs and (library.static_library or library.pic_static_library)
        )
    ]
    if shared_libraries:
        fail(("'{}' is linked fully statically (feature '{}') and thus can't depend on these " +
              "shared libraries: {}").format(
            output.short_path,
            feature_names.FULLY_STATIC_LINK,
            ", ".join(shared_libraries),
        ))
