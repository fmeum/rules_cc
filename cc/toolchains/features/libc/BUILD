# The feature that represents the choice of no libc via @platforms_contrib//os/linux/libc:preference
# or @platforms_contrib//os/windows/crt:preference.
#
# rules_cc requests it and fails if a toolchain doesn't define it, so a toolchain only lists it in its
# known_features if it can compile freestanding code and link without a libc. It doesn't add any
# flags on its own. Use it in the requires_any_of of cc_args via cc_feature_constraint.

load("//cc/toolchains:feature.bzl", "cc_feature")

package(default_visibility = ["//visibility:public"])

cc_feature(
    name = "no_libc",
    feature_name = "no_libc",
)

filegroup(
    name = "srcs",
    srcs = glob(["**"]),
)
