"""Tests for the consistency between linkage preferences, features and link modes."""

load("@platforms_contrib//os/linux/cxx_runtime/libcxx:libcxx.bzl", "libcxx_version_constraints")
load("@platforms_contrib//os/linux/cxx_runtime/libstdcxx:libstdcxx.bzl", "libstdcxx_version_constraints")
load("@platforms_contrib//os/linux/libc/glibc:glibc.bzl", "glibc_version_constraints")
load("@platforms_contrib//os/linux/libc/musl:musl.bzl", "musl_version_constraints")
load("@platforms_contrib//os/windows/cxx_runtime/msvcp:msvcp.bzl", "msvcp_version_constraints")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "util")
load("//cc:cc_binary.bzl", _cc_binary = "cc_binary")
load("//cc:cc_import.bzl", "cc_import")
load("//cc:cc_library.bzl", "cc_library")
load("//cc:cc_shared_library.bzl", "cc_shared_library")
load("//cc:cc_test.bzl", _cc_test = "cc_test")
load("//cc/cxx_runtime:cxx_runtime.bzl", "PreferredCxxRuntimeInfo")
load("//tests/cc/testutil:cc_analysis_test.bzl", "cc_analysis_test")
load("//tests/cc/testutil:link_action_subject.bzl", "link_action_subject")
load("//tests/cc/testutil/toolchains:features.bzl", "FEATURE_NAMES")

_LIBC = str(Label("@platforms_contrib//os/linux/libc:preference"))
_CRT = str(Label("@platforms_contrib//os/windows/crt:preference"))
_CXX = str(Label("//cc/cxx_runtime:preference"))
_DYNAMIC_MODE = "//command_line_option:dynamic_mode"
_MOCK_MALLOC = "//tests/cc/testutil/toolchains:mock_malloc"

_CXX_RUNTIME_FEATURES = [
    FEATURE_NAMES.bundled_cxx_runtime,
    FEATURE_NAMES.dynamic_cxx_runtime,
    FEATURE_NAMES.libcxx_runtime,
    FEATURE_NAMES.libstdcxx_runtime,
    FEATURE_NAMES.no_cxx_runtime,
    FEATURE_NAMES.static_cxx_runtime,
    FEATURE_NAMES.system_cxx_runtime,
]

_UNIX_TOOLCHAIN = [
    FEATURE_NAMES.do_not_split_linking_cmdline,
    FEATURE_NAMES.dynamic_linking_mode,
    FEATURE_NAMES.fully_static_link,
    FEATURE_NAMES.no_libc,
    FEATURE_NAMES.static_link_cpp_runtimes,
    FEATURE_NAMES.static_linking_mode,
    FEATURE_NAMES.supports_dynamic_linker,
    FEATURE_NAMES.supports_pic,
] + _CXX_RUNTIME_FEATURES

_WINDOWS_TOOLCHAIN = [
    FEATURE_NAMES.copy_dynamic_libraries_to_binary,
    FEATURE_NAMES.dynamic_link_msvcrt,
    FEATURE_NAMES.hybrid_crt,
    FEATURE_NAMES.msvcp_runtime,
    FEATURE_NAMES.static_link_msvcrt,
    FEATURE_NAMES.targets_windows,
] + _UNIX_TOOLCHAIN

# A toolchain that only knows the established features.
_LEGACY_TOOLCHAIN = [
    FEATURE_NAMES.do_not_split_linking_cmdline,
    FEATURE_NAMES.dynamic_linking_mode,
    FEATURE_NAMES.static_link_cpp_runtimes,
    FEATURE_NAMES.static_linking_mode,
    FEATURE_NAMES.supports_dynamic_linker,
    FEATURE_NAMES.supports_pic,
]

_STATIC_RUNTIME = "libmock_cxx_runtime.a"
_DYNAMIC_RUNTIME = "libmock_cxx_runtime.so"
_STATIC_DEP = "liblinkage_tests_lib.a"
_DYNAMIC_DEP_IN_SOLIB = "liblinkage_Utests_Ulib.so"
_DYNAMIC_DEP = "liblinkage_tests_lib.so"

def _expect_link(
        *,
        runtime,
        dep,
        mode,
        flags = [],
        no_flags = []):
    """Asserts on the link action of a target.

    Args:
      runtime: Which runtime library file is linked, either "static", "dynamic" or "none".
      dep: Which form of the cc_library dep is linked, either "static" or "dynamic".
      mode: The value of the linking mode feature, either "static" or "dynamic".
      flags: Flags that have to be on the command line.
      no_flags: Flags that must not be on the command line.

    Returns:
      The test implementation.
    """
    runfiles_runtime = runtime == "dynamic"

    def impl(env, target):
        action = link_action_subject.from_target(env, target)
        inputs = action.inputs()
        if runtime == "static":
            inputs.contains_predicate(matching.file_basename_equals(_STATIC_RUNTIME))
        else:
            inputs.not_contains_predicate(matching.file_basename_equals(_STATIC_RUNTIME))
        if runtime == "dynamic":
            inputs.contains_predicate(matching.file_basename_equals(_DYNAMIC_RUNTIME))
        else:
            inputs.not_contains_predicate(matching.file_basename_equals(_DYNAMIC_RUNTIME))
        if dep == "static":
            inputs.contains_predicate(matching.file_basename_equals(_STATIC_DEP))
            inputs.not_contains_predicate(matching.file_basename_contains(_DYNAMIC_DEP_IN_SOLIB))
        else:
            inputs.contains_predicate(matching.file_basename_contains(_DYNAMIC_DEP_IN_SOLIB))
            inputs.not_contains_predicate(matching.file_basename_equals(_STATIC_DEP))
        env.expect.that_str(action.actual.env["linking_mode"]).equals(mode)
        argv = action.argv()
        for flag in flags:
            argv.contains(flag)
        for flag in no_flags:
            argv.not_contains(flag)
        runfiles = env.expect.that_target(target).runfiles()
        if runfiles_runtime:
            runfiles.contains_predicate(matching.str_endswith(_DYNAMIC_RUNTIME))
        else:
            runfiles.not_contains_predicate(matching.str_endswith(_DYNAMIC_RUNTIME))
        rpath = [arg for arg in action.actual.argv if "ORIGIN" in arg and "_solib__" in arg]
        env.expect.where(argv = action.actual.argv).that_bool(bool(rpath)).equals(runfiles_runtime)

    return impl

def _expect_failure(message):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.contains(message))

    return impl

def _expect_cxx_runtime(status, flavor = None, linkage = None, diagnostic = ""):
    def impl(env, target):
        info = target[PreferredCxxRuntimeInfo]
        env.expect.that_str(info.status).equals(status)
        env.expect.that_bool(info.flavor == flavor).equals(True)
        env.expect.that_bool(info.linkage == linkage).equals(True)
        env.expect.that_str(info.diagnostic).contains(diagnostic)

    return impl

def _expect_only_static_outputs(env, target):
    env.expect.that_target(target).default_outputs().not_contains_predicate(
        matching.file_basename_contains(".so"),
    )

def _expect_dynamic_outputs(env, target):
    env.expect.that_target(target).default_outputs().contains_predicate(
        matching.file_basename_equals(_DYNAMIC_DEP),
    )

def _expect_compile_flags(flags, no_flags = []):
    def impl(env, target):
        action = env.expect.that_target(target).action_named("CppCompile")
        for flag in flags:
            action.argv().contains(flag)
        for flag in no_flags:
            action.argv().not_contains(flag)

    return impl

def _exec_preferred_impl(ctx):
    return [ctx.attr.preferred[PreferredCxxRuntimeInfo]]

_exec_preferred = rule(
    implementation = _exec_preferred_impl,
    attrs = {"preferred": attr.label(cfg = "exec", default = "//cc/cxx_runtime:preferred")},
)

def _select_subject_impl(ctx):
    return [DefaultInfo(), _SelectedInfo(preferred = ctx.attr.preferred, effective = ctx.attr.effective, libc = ctx.attr.libc)]

_SelectedInfo = provider(doc = "The result of selecting on the settings.", fields = ["preferred", "effective", "libc"])

_select_subject = rule(
    implementation = _select_subject_impl,
    attrs = {"preferred": attr.string(), "effective": attr.string(), "libc": attr.string()},
)

def _expect_selected(preferred, effective):
    def impl(env, target):
        env.expect.that_str(target[_SelectedInfo].preferred).equals(preferred)
        env.expect.that_str(target[_SelectedInfo].effective).equals(effective)

    return impl

def _expect_selected_libc(libc):
    def impl(env, target):
        env.expect.that_str(target[_SelectedInfo].libc).equals(libc)

    return impl

def _helpers(name):
    def t(suffix):
        return "{}_{}".format(name, suffix)

    def cc_binary(name, **kwargs):
        util.helper_target(_cc_binary, name = name, malloc = _MOCK_MALLOC, **kwargs)

    def cc_test(name, **kwargs):
        util.helper_target(_cc_test, name = name, malloc = _MOCK_MALLOC, **kwargs)

    util.helper_target(cc_library, name = t("lib"), srcs = ["lib.cc"])
    util.helper_target(cc_shared_library, name = t("shared"), shared_lib_name = "libshared.so", deps = [t("lib")])
    util.helper_target(cc_import, name = t("shared_only"), shared_library = "libfoo.so")
    common = dict(srcs = ["main.cc"], deps = [t("lib")])
    cc_binary(t("bin"), **common)
    cc_binary(t("bin_linkstatic_0"), linkstatic = False, **common)
    cc_test(t("test"), **common)
    cc_test(t("test_fully_static"), features = [FEATURE_NAMES.fully_static_link], **common)
    cc_binary(t("bin_fully_static"), features = [FEATURE_NAMES.fully_static_link], **common)
    cc_binary(t("bin_no_fully_static"), features = ["-" + FEATURE_NAMES.fully_static_link], **common)
    cc_test(t("test_static_cxx_runtime"), features = [FEATURE_NAMES.static_cxx_runtime], **common)
    cc_binary(t("bin_dynamic_cxx_runtime"), features = [FEATURE_NAMES.dynamic_cxx_runtime], **common)
    cc_binary(t("bin_no_libc"), features = [FEATURE_NAMES.no_libc], **common)
    cc_binary(t("bin_with_libc"), features = ["-" + FEATURE_NAMES.no_libc], **common)
    cc_binary(t("bin_no_cxx_runtime"), features = [FEATURE_NAMES.no_cxx_runtime], **common)
    cc_binary(t("bin_static_msvcrt"), features = [FEATURE_NAMES.static_link_msvcrt], **common)
    cc_binary(t("bin_dynamic_msvcrt"), features = [FEATURE_NAMES.dynamic_link_msvcrt], **common)
    cc_binary(t("bin_dynamic_deps"), srcs = ["main.cc"], dynamic_deps = [t("shared")], deps = [t("lib")])
    cc_binary(
        t("bin_dynamic_deps_fully_static"),
        srcs = ["main.cc"],
        dynamic_deps = [t("shared")],
        features = [FEATURE_NAMES.fully_static_link],
        deps = [t("lib")],
    )
    cc_binary(
        t("bin_shared_only_fully_static"),
        srcs = ["main.cc"],
        features = [FEATURE_NAMES.fully_static_link],
        deps = [t("shared_only")],
    )
    cc_binary(t("bin_linkshared"), linkshared = True, **common)

    util.helper_target(
        _select_subject,
        name = t("select"),
        preferred = select({
            "//cc/cxx_runtime:static_preferred": "static",
            "//cc/cxx_runtime:system_preferred": "system",
            "//cc/cxx_runtime:bundled_preferred": "bundled",
            "//cc/cxx_runtime:none_preferred": "none",
            "//cc/cxx_runtime:unset": "unset",
            "//conditions:default": "other",
        }),
        effective = select({
            "//cc/cxx_runtime:static": "static",
            "//cc/cxx_runtime:dynamic": "dynamic",
            "//conditions:default": "unknown",
        }),
        libc = select({
            "//cc/libc:glibc": "glibc",
            "//cc/libc:none": "none",
            "//conditions:default": "other",
        }),
    )
    util.helper_target(_exec_preferred, name = t("exec_preferred"))

    for platform, constraints in {
        "linux": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
        "glibc": ["@platforms//os:linux", "@platforms//cpu:x86_64"] + glibc_version_constraints("2.35"),
        "glibc_libstdcxx": ["@platforms//os:linux", "@platforms//cpu:x86_64"] + glibc_version_constraints("2.35") + libstdcxx_version_constraints("13"),
        "glibc_libcxx": ["@platforms//os:linux", "@platforms//cpu:x86_64"] + glibc_version_constraints("2.35") + libcxx_version_constraints("20"),
        "musl": ["@platforms//os:linux", "@platforms//cpu:x86_64"] + musl_version_constraints("1.2"),
        "macos": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
        "windows": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
        "windows_vcredist": ["@platforms//os:windows", "@platforms//cpu:x86_64"] + msvcp_version_constraints("14.40"),
    }.items():
        native.platform(name = t(platform), constraint_values = constraints)

def linkage_test_suite(name):
    """Declares the tests.

    Args:
      name: The name of the test suite.
    """
    _helpers(name)
    tests = []

    def add(test, target, impl, *, platform = "glibc", toolchain = _UNIX_TOOLCHAIN, libc = None, crt = None, cxx = None, flags = {}, expect_failure = False, **kwargs):
        test_name = "{}_{}_test".format(name, test)
        settings = {"//command_line_option:platforms": str(Label(":{}_{}".format(name, platform)))} | flags
        if libc != None:
            settings[_LIBC] = libc
        if crt != None:
            settings[_CRT] = crt
        if cxx != None:
            settings[_CXX] = cxx
        cc_analysis_test(
            name = test_name,
            target = ":{}_{}".format(name, target),
            impl = impl,
            with_features = toolchain,
            config_settings = settings,
            expect_failure = expect_failure,
            **kwargs
        )
        tests.append(test_name)

    def add_failure(test, target, message, **kwargs):
        add(test, target, _expect_failure(message), expect_failure = True, **kwargs)

    ### Resolving the ranking.

    preferred = "@rules_cc//cc/cxx_runtime:preferred"
    for test, platform, libc, crt, cxx, impl in [
        ("default", "glibc", None, None, None, _expect_cxx_runtime("unset")),
        ("static", "linux", None, None, ["static-libc++"], _expect_cxx_runtime("resolved", "libc++", "static")),
        ("bundled", "linux", None, None, ["bundled-libstdc++"], _expect_cxx_runtime("resolved", "libstdc++", "bundled")),
        ("system_declared", "glibc_libstdcxx", None, None, ["libstdc++"], _expect_cxx_runtime("resolved", "libstdc++", "system")),
        ("system_undeclared_falls_through", "glibc", None, None, ["libstdc++", "static-libc++"], _expect_cxx_runtime("resolved", "libc++", "static")),
        ("system_other_flavor_declared", "glibc_libcxx", None, None, ["libstdc++", "libc++"], _expect_cxx_runtime("resolved", "libc++", "system")),
        ("system_undeclared_unresolved", "glibc", None, None, ["libstdc++"], _expect_cxx_runtime("unresolved", diagnostic = "the platform doesn't declare libstdc++ as available")),
        ("static_libc_rules_out_system", "glibc_libstdcxx", ["static-glibc"], None, ["libstdc++", "static-libstdc++"], _expect_cxx_runtime("resolved", "libstdc++", "static")),
        ("static_libc_rules_out_bundled", "glibc", ["static-glibc"], None, ["bundled-libc++"], _expect_cxx_runtime("unresolved", diagnostic = "a statically linked libc can't be combined with a shared C++ runtime")),
        ("msvcp_is_windows_only", "glibc", None, None, ["static-msvcp", "static-libc++"], _expect_cxx_runtime("resolved", "libc++", "static")),
        ("macos_system_libcxx", "macos", None, None, ["libc++"], _expect_cxx_runtime("resolved", "libc++", "system")),
        ("macos_no_libstdcxx", "macos", None, None, ["libstdc++", "bundled-libstdc++", "static-libstdc++", "static-libc++"], _expect_cxx_runtime("resolved", "libc++", "static")),
        ("windows_vcredist_declared", "windows_vcredist", None, None, ["msvcp"], _expect_cxx_runtime("resolved", "msvcp", "system")),
        ("windows_vcredist_undeclared", "windows", None, None, ["msvcp", "bundled-msvcp"], _expect_cxx_runtime("resolved", "msvcp", "bundled")),
        ("windows_static_crt_rules_out_dynamic", "windows_vcredist", None, ["static-ucrt"], ["msvcp", "static-msvcp"], _expect_cxx_runtime("resolved", "msvcp", "static")),
        ("none_on_hosted_libc", "glibc", None, None, ["none"], _expect_cxx_runtime("resolved", "none", "none")),
        ("none_as_fallback", "glibc", None, None, ["libstdc++", "none"], _expect_cxx_runtime("resolved", "none", "none")),
        ("none_on_macos", "macos", None, None, ["none"], _expect_cxx_runtime("resolved", "none", "none")),
        ("no_libc_implies_none", "glibc", ["none"], None, None, _expect_cxx_runtime("resolved", "none", "none")),
        ("no_libc_falls_through_to_none", "glibc", ["none"], None, ["static-libc++", "none"], _expect_cxx_runtime("resolved", "none", "none")),
        ("no_libc_rules_out_static", "glibc", ["none"], None, ["static-libc++"], _expect_cxx_runtime("unresolved", diagnostic = "a C++ runtime can't be used without a libc")),
        ("no_libc_rules_out_system", "glibc_libstdcxx", ["none"], None, ["libstdc++"], _expect_cxx_runtime("unresolved", diagnostic = "Rank \"none\"")),
        ("no_crt_implies_none", "windows", None, ["none"], None, _expect_cxx_runtime("resolved", "none", "none")),
        ("no_crt_rules_out_msvcp", "windows", None, ["none"], ["static-msvcp"], _expect_cxx_runtime("unresolved", diagnostic = "a C++ runtime can't be used without a libc")),
    ]:
        test_name = "{}_resolve_{}_test".format(name, test)
        settings = {"//command_line_option:platforms": str(Label(":{}_{}".format(name, platform)))}
        if libc != None:
            settings[_LIBC] = libc
        if crt != None:
            settings[_CRT] = crt
        if cxx != None:
            settings[_CXX] = cxx
        cc_analysis_test(name = test_name, target = preferred, impl = impl, config_settings = settings)
        tests.append(test_name)

    add("exec_uses_default", "exec_preferred", _expect_cxx_runtime("unset"), cxx = ["static-libc++"])

    ### Legacy behavior without preferences: the C++ runtime follows the link mode.

    add("legacy_binary", "bin", _expect_link(runtime = "static", dep = "static", mode = "static"), toolchain = _LEGACY_TOOLCHAIN)
    add("legacy_test", "test", _expect_link(runtime = "dynamic", dep = "dynamic", mode = "dynamic"), toolchain = _LEGACY_TOOLCHAIN)
    add("legacy_test_on_new_toolchain", "test", _expect_link(runtime = "dynamic", dep = "dynamic", mode = "dynamic"))
    add("legacy_library_keeps_shared_output", "lib", _expect_dynamic_outputs)

    ### fully_static_link is honored by the link mode with and without preferences.

    fully_static = _expect_link(runtime = "static", dep = "static", mode = "static", flags = ["<fully_static_link>"])
    add("feature_fully_static_test", "test_fully_static", fully_static)
    add("feature_fully_static_binary", "bin_fully_static", fully_static)
    add("feature_fully_static_wins_over_dynamic_mode", "bin_fully_static", fully_static, flags = {_DYNAMIC_MODE: "fully"})
    add("feature_fully_static_overrides_bundled_runtime", "test_fully_static", fully_static, cxx = ["bundled-libc++"])
    add("feature_fully_static_dynamic_deps", "bin_dynamic_deps_fully_static", _expect_failure("can't depend on these shared libraries: "), expect_failure = True)
    add("feature_fully_static_shared_only_import", "bin_shared_only_fully_static", _expect_failure("libfoo.so"), expect_failure = True)

    ### The libc preference.

    add("libc_static_binary", "bin", fully_static, libc = ["static-glibc"])
    add("libc_static_test", "test", fully_static, libc = ["static-glibc"])
    add("libc_static_library_has_no_shared_output", "lib", _expect_only_static_outputs, libc = ["static-glibc"])
    add("libc_glibc_library_has_shared_output", "lib", _expect_dynamic_outputs, libc = ["glibc"])
    add_failure("libc_static_disabled_feature", "bin_no_fully_static", "Disabling the feature 'fully_static_link' conflicts with", libc = ["static-glibc"])
    add_failure("libc_static_dynamic_mode", "bin", "--dynamic_mode=fully conflicts with", libc = ["static-glibc"], flags = {_DYNAMIC_MODE: "fully"})
    add_failure("libc_static_shared_library", "shared", "can't be linked since", libc = ["static-glibc"])
    add_failure("libc_static_linkshared", "bin_linkshared", "can't be linked since", libc = ["static-glibc"])
    add_failure("libc_static_dynamic_runtime_override", "bin_dynamic_cxx_runtime", "conflicts with", libc = ["static-glibc"], cxx = ["static-libc++"])
    add_failure("libc_flavor_mismatch", "bin", "targets glibc, but", libc = ["static-musl"])

    ### No libc.

    no_libc = _expect_link(runtime = "none", dep = "static", mode = "static", flags = ["<no_libc>", "<no_cxx_runtime>", "<fully_static_link>"], no_flags = ["<static_cxx_runtime>", "<dynamic_cxx_runtime>"])
    add("no_libc_binary", "bin", no_libc, libc = ["none"])
    add("no_libc_test", "test", no_libc, libc = ["none"])
    add("no_libc_linkstatic_0", "bin_linkstatic_0", no_libc, libc = ["none"])
    add("no_libc_platform_without_libc", "bin", no_libc, platform = "linux", libc = ["none"])
    add("no_libc_compile", "lib", _expect_compile_flags(["<no_libc>", "<no_cxx_runtime>"]), libc = ["none"])
    add("no_libc_library_has_no_shared_output", "lib", _expect_only_static_outputs, libc = ["none"])
    add("no_libc_allows_shared_library", "shared", _expect_shared_library, libc = ["none"])
    add("no_libc_allows_linkshared", "bin_linkshared", _expect_shared_library_link, libc = ["none"])
    add("no_libc_toolchain_reports_none", "select", _expect_selected_libc("none"), libc = ["none"])
    add("hosted_toolchain_reports_its_libc", "select", _expect_selected_libc("glibc"))
    add_failure("no_libc_dynamic_deps", "bin_dynamic_deps", "can't depend on these shared libraries: ", libc = ["none"])
    add_failure("no_libc_shared_only_import", "bin_shared_only_fully_static", "libfoo.so", libc = ["none"])
    add_failure("no_libc_disabled_fully_static", "bin_no_fully_static", "Disabling the feature 'fully_static_link' conflicts with", libc = ["none"])
    add_failure("no_libc_disabled_feature", "bin_with_libc", "Disabling the feature 'no_libc' conflicts with", libc = ["none"])
    add_failure("no_libc_dynamic_mode", "bin", "--dynamic_mode=fully conflicts with", libc = ["none"], flags = {_DYNAMIC_MODE: "fully"})
    add_failure("no_libc_static_runtime_override", "test_static_cxx_runtime", "The feature 'static_cxx_runtime' conflicts with the choice of no C++ runtime", libc = ["none"])
    add_failure("no_libc_dynamic_runtime_override", "bin_dynamic_cxx_runtime", "The feature 'dynamic_cxx_runtime' conflicts with the choice of no C++ runtime", libc = ["none"])
    add_failure("no_libc_cxx_ranking", "bin", "None of the C++ runtime options", libc = ["none"], cxx = ["static-libc++"])
    add_failure("no_libc_feature_on_hosted_libc", "bin_no_libc", "The feature 'no_libc' conflicts with --@platforms_contrib//os/linux/libc:preference, which chose glibc", libc = ["glibc"])
    add_failure("no_libc_legacy_toolchain", "bin", "can't deliver the choice made by --@platforms_contrib//os/linux/libc:preference since it doesn't define the feature 'no_libc'", toolchain = _LEGACY_TOOLCHAIN + [FEATURE_NAMES.fully_static_link], libc = ["none"])
    add_failure("no_libc_without_no_cxx_runtime", "bin", "can't deliver the choice made by --@platforms_contrib//os/linux/libc:preference since it doesn't define the feature 'no_cxx_runtime'", toolchain = _LEGACY_TOOLCHAIN + [FEATURE_NAMES.fully_static_link, FEATURE_NAMES.no_libc], libc = ["none"])

    ### The C++ runtime preference.

    static_runtime = _expect_link(runtime = "static", dep = "static", mode = "static", flags = ["<static_cxx_runtime>", "<libcxx_runtime>"], no_flags = ["<dynamic_cxx_runtime>"])
    add("cxx_static_binary", "bin", static_runtime, cxx = ["static-libc++"])
    add("cxx_static_test", "test", static_runtime, cxx = ["static-libc++"])
    add("cxx_static_linkstatic_0", "bin_linkstatic_0", static_runtime, cxx = ["static-libc++"])
    add("cxx_static_library_has_no_shared_output", "lib", _expect_only_static_outputs, cxx = ["static-libc++"])
    add("cxx_static_dynamic_deps_allowed", "bin_dynamic_deps", _expect_link_only_runtime("static"), cxx = ["static-libc++"])
    add_failure("cxx_static_dynamic_mode", "bin", "--dynamic_mode=fully conflicts with", cxx = ["static-libc++"], flags = {_DYNAMIC_MODE: "fully"})

    # Libraries and the C++ runtime are linked independently of each other.
    bundled_with_static_deps = _expect_link(runtime = "dynamic", dep = "static", mode = "static", flags = ["<dynamic_cxx_runtime>", "<bundled_cxx_runtime>"])
    bundled_with_dynamic_deps = _expect_link(runtime = "dynamic", dep = "dynamic", mode = "dynamic", flags = ["<dynamic_cxx_runtime>", "<bundled_cxx_runtime>"])
    add("cxx_bundled_binary", "bin", bundled_with_static_deps, cxx = ["bundled-libc++"])
    add("cxx_bundled_test", "test", bundled_with_dynamic_deps, cxx = ["bundled-libc++"])
    add("cxx_bundled_dynamic_mode_fully", "bin", bundled_with_dynamic_deps, cxx = ["bundled-libc++"], flags = {_DYNAMIC_MODE: "fully"})
    add("cxx_bundled_dynamic_mode_off", "test", bundled_with_static_deps, cxx = ["bundled-libc++"], flags = {_DYNAMIC_MODE: "off"})
    add("cxx_bundled_shared_library_runfiles", "shared", _expect_runtime_in_runfiles, cxx = ["bundled-libc++"])

    system_with_static_deps = _expect_link(runtime = "none", dep = "static", mode = "static", flags = ["<dynamic_cxx_runtime>", "<system_cxx_runtime>", "<libstdcxx_runtime>"])
    add("cxx_system_binary", "bin", system_with_static_deps, platform = "glibc_libstdcxx", cxx = ["libstdc++"])
    add("cxx_system_test", "test", _expect_link(runtime = "none", dep = "dynamic", mode = "dynamic"), platform = "glibc_libstdcxx", cxx = ["libstdc++"])
    add_failure("cxx_unresolved", "bin", "None of the C++ runtime options", cxx = ["libstdc++"])

    # The libc stays and the libraries of the binary follow the link mode.
    add("cxx_none_binary", "bin", _expect_link(runtime = "none", dep = "static", mode = "static", flags = ["<no_cxx_runtime>"], no_flags = ["<no_libc>", "<fully_static_link>", "<static_cxx_runtime>", "<dynamic_cxx_runtime>"]), cxx = ["none"])
    add("cxx_none_test", "test", _expect_link(runtime = "none", dep = "dynamic", mode = "dynamic", flags = ["<no_cxx_runtime>"]), cxx = ["none"])
    add("cxx_none_library_keeps_shared_output", "lib", _expect_dynamic_outputs, cxx = ["none"])
    add("cxx_none_per_target_on_unset_ranking", "bin_no_cxx_runtime", _expect_compile_flags(["<no_cxx_runtime>"]))
    add_failure("cxx_none_static_override", "test_static_cxx_runtime", "The feature 'static_cxx_runtime' conflicts with the choice of no C++ runtime", cxx = ["none"])
    add_failure("cxx_none_feature_on_static_ranking", "bin_no_cxx_runtime", "The feature 'no_cxx_runtime' conflicts with --@rules_cc//cc/cxx_runtime:preference", cxx = ["static-libc++"])
    add_failure("cxx_none_legacy_toolchain", "bin", "can't deliver the choice made by --@rules_cc//cc/cxx_runtime:preference since it doesn't define the feature 'no_cxx_runtime'", toolchain = _LEGACY_TOOLCHAIN, cxx = ["none"])

    # static_libgcc would add a second unwinder to a binary that uses a shared C++ runtime.
    add("cxx_bundled_drops_static_libgcc", "bin", _expect_link(runtime = "dynamic", dep = "static", mode = "static", no_flags = ["-static-libgcc"]), cxx = ["bundled-libc++"])

    ### Per-target overrides that only affect the link.

    add("override_static_on_bundled", "test_static_cxx_runtime", _expect_link(runtime = "static", dep = "static", mode = "static", flags = ["<static_cxx_runtime>"], no_flags = ["<dynamic_cxx_runtime>", "<bundled_cxx_runtime>"]), cxx = ["bundled-libc++"])
    add("override_static_on_legacy", "test_static_cxx_runtime", _expect_link(runtime = "static", dep = "static", mode = "static", flags = ["<static_cxx_runtime>"]))
    add("override_dynamic_on_static", "bin_dynamic_cxx_runtime", _expect_link(runtime = "dynamic", dep = "static", mode = "static", flags = ["<dynamic_cxx_runtime>"], no_flags = ["<static_cxx_runtime>"]), cxx = ["static-libc++"])
    add("override_dynamic_on_legacy", "bin_dynamic_cxx_runtime", _expect_link(runtime = "dynamic", dep = "static", mode = "static", flags = ["<dynamic_cxx_runtime>"]))

    ### Toolchains that can't deliver fail instead of being ignored.

    add_failure("legacy_toolchain_static", "bin", "can't deliver the choice made by --@rules_cc//cc/cxx_runtime:preference since it doesn't define the feature 'static_cxx_runtime'", toolchain = _LEGACY_TOOLCHAIN, cxx = ["static-libc++"])
    add_failure("legacy_toolchain_flavor", "bin", "doesn't define the feature 'libstdcxx_runtime'", toolchain = _LEGACY_TOOLCHAIN + [FEATURE_NAMES.static_cxx_runtime], cxx = ["static-libstdc++"])
    add_failure("no_hybrid_crt", "bin", "doesn't define the feature 'hybrid_crt'", platform = "windows", toolchain = [f for f in _WINDOWS_TOOLCHAIN if f != FEATURE_NAMES.hybrid_crt], crt = ["ucrt"], cxx = ["static-msvcp"])
    add_failure("no_static_crt", "bin", "doesn't define the feature 'static_link_msvcrt'", platform = "windows", toolchain = [f for f in _WINDOWS_TOOLCHAIN if f != FEATURE_NAMES.static_link_msvcrt], crt = ["static-ucrt"])

    ### Windows, where the CRT and C++ runtime linkage affect compilation.

    win = dict(platform = "windows", toolchain = _WINDOWS_TOOLCHAIN)
    add("win_default_leaves_crt_to_toolchain", "lib", _expect_compile_flags([], ["<static_link_msvcrt>", "<dynamic_link_msvcrt>"]), **win)
    add("win_static_crt_compile", "lib", _expect_compile_flags(["<static_link_msvcrt>", "<static_cxx_runtime>"], ["<dynamic_link_msvcrt>", "<hybrid_crt>"]), crt = ["static-ucrt"], cxx = ["static-msvcp"], **win)
    add("win_dynamic_crt_compile", "lib", _expect_compile_flags(["<dynamic_link_msvcrt>"], ["<static_link_msvcrt>"]), crt = ["ucrt"], cxx = ["bundled-msvcp"], **win)
    add("win_hybrid_compile", "lib", _expect_compile_flags(["<static_link_msvcrt>", "<hybrid_crt>", "<static_cxx_runtime>"], ["<dynamic_link_msvcrt>"]), crt = ["ucrt"], cxx = ["static-msvcp"], **win)
    add("win_static_libcxx_keeps_dynamic_crt", "lib", _expect_compile_flags(["<dynamic_link_msvcrt>", "<static_cxx_runtime>"], ["<static_link_msvcrt>"]), crt = ["ucrt"], cxx = ["static-libc++"], **win)
    add("win_static_runtime_keeps_shared_library_output", "lib", _expect_dynamic_outputs_on_windows, crt = ["static-ucrt"], cxx = ["static-msvcp"], **win)
    add("win_static_crt_allows_shared_library", "shared", _expect_shared_library, crt = ["static-ucrt"], cxx = ["static-msvcp"], **win)
    add_failure("win_static_crt_rejects_dynamic_feature", "bin_dynamic_msvcrt", "The feature 'dynamic_link_msvcrt' conflicts with", crt = ["static-ucrt"], **win)
    add_failure("win_dynamic_crt_rejects_static_feature", "bin_static_msvcrt", "The feature 'static_link_msvcrt' conflicts with", crt = ["ucrt"], **win)
    add_failure("win_rejects_runtime_override", "bin_dynamic_cxx_runtime", "The C++ runtime affects compilation on Windows", crt = ["ucrt"], cxx = ["static-msvcp"], **win)
    add_failure("win_rejects_fully_static_override", "bin_fully_static", "The C++ runtime affects compilation on Windows", crt = ["ucrt"], cxx = ["bundled-msvcp"], **win)
    add_failure("win_flavor_mismatch", "bin", "targets ucrt, but", crt = ["msvcrt"], **win)

    # Without a CRT, dynamic linking still works and there is no fully static link.
    add("win_no_crt_compile", "lib", _expect_compile_flags(["<no_libc>", "<no_cxx_runtime>"], ["<static_link_msvcrt>", "<dynamic_link_msvcrt>", "<fully_static_link>"]), crt = ["none"], **win)
    add("win_no_crt_keeps_shared_library_output", "lib", _expect_dynamic_outputs_on_windows, crt = ["none"], **win)
    add("win_no_crt_allows_shared_library", "shared", _expect_shared_library, crt = ["none"], **win)
    add("win_no_crt_reports_none", "select", _expect_selected_libc("none"), crt = ["none"], **win)
    add_failure("win_no_crt_rejects_static_feature", "bin_static_msvcrt", "The feature 'static_link_msvcrt' conflicts with", crt = ["none"], **win)
    add_failure("win_no_crt_rejects_dynamic_feature", "bin_dynamic_msvcrt", "The feature 'dynamic_link_msvcrt' conflicts with", crt = ["none"], **win)
    add_failure("win_no_crt_requires_feature", "bin", "can't deliver the choice made by --@platforms_contrib//os/windows/crt:preference since it doesn't define the feature 'no_libc'", platform = "windows", toolchain = [f for f in _WINDOWS_TOOLCHAIN if f != FEATURE_NAMES.no_libc], crt = ["none"])
    add_failure("win_no_libc_feature_on_ucrt", "bin_no_libc", "The feature 'no_libc' conflicts with --@platforms_contrib//os/windows/crt:preference, which chose ucrt", crt = ["ucrt"], **win)

    # A static CRT implies a static C++ runtime even if the ranking doesn't say so.
    add("win_static_crt_implies_static_runtime", "test", _expect_link_only_runtime("static"), crt = ["static-ucrt"], **win)

    # Without a preference, per-target CRT features keep working.
    add("win_legacy_per_target_static_crt", "bin_static_msvcrt", _expect_compile_flags(["<static_link_msvcrt>"]), **win)

    ### select().

    add("select_unset", "select", _expect_selected("unset", "unknown"))
    add("select_static", "select", _expect_selected("static", "static"), cxx = ["static-libc++"])
    add("select_bundled", "select", _expect_selected("bundled", "dynamic"), cxx = ["bundled-libc++"])
    add("select_none", "select", _expect_selected("none", "unknown"), cxx = ["none"])

    native.test_suite(name = name, tests = [":" + test for test in tests])

def _expect_link_only_runtime(runtime):
    def impl(env, target):
        inputs = link_action_subject.from_target(env, target).inputs()
        inputs.contains_predicate(matching.file_basename_equals(_STATIC_RUNTIME if runtime == "static" else _DYNAMIC_RUNTIME))

    return impl

def _expect_runtime_in_runfiles(env, target):
    env.expect.that_target(target).runfiles().contains_predicate(matching.str_endswith(_DYNAMIC_RUNTIME))

def _expect_dynamic_outputs_on_windows(env, target):
    env.expect.that_target(target).default_outputs().contains_predicate(matching.file_basename_contains("lib"))

def _expect_shared_library(env, target):
    env.expect.that_target(target).default_outputs().contains_predicate(matching.file_basename_contains("libshared"))

def _expect_shared_library_link(env, target):
    env.expect.that_target(target).action_named("CppLink")
