# The features that represent a choice made via @rules_cc//cc/cxx_runtime:preference.
#
# rules_cc requests the matching features and fails if a toolchain doesn't define them, so a toolchain
# only lists the features for the options it can deliver in its known_features. They don't add
# any flags on their own. Use them in the requires_any_of of cc_args via cc_feature_constraint.

load("//cc/toolchains:feature.bzl", "cc_feature")
load("//cc/toolchains:feature_set.bzl", "cc_feature_set")
load("//cc/toolchains:mutually_exclusive_category.bzl", "cc_mutually_exclusive_category")

package(default_visibility = ["//visibility:public"])

cc_mutually_exclusive_category(name = "cxx_runtime_linkage")

cc_mutually_exclusive_category(name = "cxx_runtime_provenance")

cc_mutually_exclusive_category(name = "cxx_runtime_flavor")

cc_feature(
    name = "static_cxx_runtime",
    feature_name = "static_cxx_runtime",
    mutually_exclusive = [":cxx_runtime_linkage"],
)

cc_feature(
    name = "dynamic_cxx_runtime",
    feature_name = "dynamic_cxx_runtime",
    mutually_exclusive = [":cxx_runtime_linkage"],
)

cc_feature(
    name = "no_cxx_runtime",
    feature_name = "no_cxx_runtime",
    mutually_exclusive = [":cxx_runtime_linkage"],
)

cc_feature(
    name = "system_cxx_runtime",
    feature_name = "system_cxx_runtime",
    mutually_exclusive = [":cxx_runtime_provenance"],
)

cc_feature(
    name = "bundled_cxx_runtime",
    feature_name = "bundled_cxx_runtime",
    mutually_exclusive = [":cxx_runtime_provenance"],
)

cc_feature(
    name = "libcxx_runtime",
    feature_name = "libcxx_runtime",
    mutually_exclusive = [":cxx_runtime_flavor"],
)

cc_feature(
    name = "libstdcxx_runtime",
    feature_name = "libstdcxx_runtime",
    mutually_exclusive = [":cxx_runtime_flavor"],
)

cc_feature(
    name = "msvcp_runtime",
    feature_name = "msvcp_runtime",
    mutually_exclusive = [":cxx_runtime_flavor"],
)

cc_feature_set(
    name = "linkage_features",
    all_of = [
        ":bundled_cxx_runtime",
        ":dynamic_cxx_runtime",
        ":static_cxx_runtime",
        ":system_cxx_runtime",
    ],
)

filegroup(
    name = "srcs",
    srcs = glob(["**"]),
)
