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
"""Collects the libc, CRT and C++ runtime preferences for the C++ toolchain."""

load("@platforms_contrib//os/linux/libc:libc.bzl", "PreferredLibcInfo")
load("@platforms_contrib//os/windows/crt:crt.bzl", "PreferredWindowsCrtInfo")
load("//cc/cxx_runtime:cxx_runtime.bzl", "PreferredCxxRuntimeInfo")
load(":linkage.bzl", "create_linkage_choices")

def _linkage_choices_impl(ctx):
    return [create_linkage_choices(
        windows = ctx.target_platform_has_constraint(ctx.attr._windows[platform_common.ConstraintValueInfo]),
        preferred_libc = ctx.attr._preferred_libc[PreferredLibcInfo],
        preferred_crt = ctx.attr._preferred_crt[PreferredWindowsCrtInfo],
        cxx_runtime = ctx.attr._preferred_cxx_runtime[PreferredCxxRuntimeInfo],
    )]

linkage_choices = rule(
    implementation = _linkage_choices_impl,
    attrs = {
        "_preferred_crt": attr.label(default = "@platforms_contrib//os/windows/crt:preferred"),
        "_preferred_cxx_runtime": attr.label(default = "//cc/cxx_runtime:preferred"),
        "_preferred_libc": attr.label(default = "@platforms_contrib//os/linux/libc:preferred"),
        "_windows": attr.label(default = "@platforms//os:windows"),
    },
)
