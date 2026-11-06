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

"""The C++ runtime, which consists of a C++ standard library, its ABI library and an unwinder.

Usage:

  * Choosing the C++ runtime: set `:preference` to a ranking of options, e.g.
    `--@rules_cc//cc/cxx_runtime:preference=libstdc++,static-libc++`. Each option is one of:

      - `<flavor>`: link against the copy on the target platform, which is viable if the platform
        declares it via the constraints in `@platforms_contrib//os/*/cxx_runtime` (always for libc++
        on macOS) and the libc is linked dynamically.
      - `bundled-<flavor>`: link against a shared copy that's shipped in the runfiles, which is viable
        if the libc is linked dynamically.
      - `static-<flavor>`: link the C++ runtime into every binary.

    The flavors are `libc++`, `libstdc++` (not on macOS) and `msvcp` (Windows only). The preferred
    option is the first viable one. The default is the empty ranking, which leaves the choice to the
    C++ toolchain and links the C++ runtime the same way as the libraries of the binary.

  * Following the choice in a C++ toolchain: define the features `static_cxx_runtime`,
    `dynamic_cxx_runtime`, `system_cxx_runtime`, `bundled_cxx_runtime`, `libcxx_runtime`,
    `libstdcxx_runtime` and `msvcp_runtime` for the options the toolchain can deliver. rules_cc
    requests the matching ones and fails if the toolchain doesn't define them. It links
    `static_runtime_lib` for a static C++ runtime and `dynamic_runtime_lib` otherwise and adds the
    latter to the runfiles. For a C++ runtime from the platform, `dynamic_runtime_lib` should thus
    not contain the C++ runtime. Link against it via flags instead. Use `:*_preferred` as `select()`
    keys to choose runtime libraries and flags.

  * Following the choice in a rule that doesn't use a C++ toolchain: use `:*_preferred`, read the
    `PreferredCxxRuntimeInfo` provider (from `cxx_runtime.bzl`) of `:preferred` or add `:preferred` to
    the `toolchains` attribute of a target and use the `PREFERRED_CXX_RUNTIME`,
    `PREFERRED_CXX_RUNTIME_LINKAGE` and `PREFERRED_CXX_RUNTIME_STATUS` Make variables.

  * Diagnosing a platform without a viable option: build `:validate_preference` for it.

To make code depend on how the C++ runtime is actually linked, use `:static` and `:dynamic`, which
take per-target features and the toolchain's own choice into account.
"""

load("@bazel_skylib//:bzl_library.bzl", "bzl_library")
load(
    ":cxx_runtime_private.bzl",
    "CXX_RUNTIME_FLAVORS",
    "CXX_RUNTIME_LINKAGES",
    "cxx_runtime_linkage_flag",
    "cxx_runtime_preference_flag",
    "preferred_cxx_runtime",
    "validate_preferred_cxx_runtime",
)

package(default_visibility = ["//visibility:public"])

licenses(["notice"])

bzl_library(
    name = "cxx_runtime_bzl",
    srcs = ["cxx_runtime.bzl"],
)

cxx_runtime_preference_flag(
    name = "preference",
    build_setting_default = [],
    # Applies to the target platform only, so that a ranking doesn't affect tools built for the exec
    # platform.
    scope = "target",
)

preferred_cxx_runtime(name = "preferred")

preferred_cxx_runtime(
    name = "preferred_linkage",
    provide_linkage = True,
)

[
    config_setting(
        name = "{}_preferred".format(flavor),
        flag_values = {":preferred": flavor},
    )
    for flavor in CXX_RUNTIME_FLAVORS
]

[
    config_setting(
        name = "{}_preferred".format(linkage),
        flag_values = {":preferred_linkage": linkage},
    )
    for linkage in CXX_RUNTIME_LINKAGES
]

config_setting(
    name = "unset",
    flag_values = {":preferred": "unset"},
)

config_setting(
    name = "unresolved",
    flag_values = {":preferred": "unresolved"},
)

validate_preferred_cxx_runtime(
    name = "validate_preference",
    tags = ["manual"],
)

cxx_runtime_linkage_flag(name = "linkage")

config_setting(
    name = "static",
    flag_values = {":linkage": "static"},
)

config_setting(
    name = "dynamic",
    flag_values = {":linkage": "dynamic"},
)

filegroup(
    name = "srcs",
    srcs = glob(["**"]),
)
