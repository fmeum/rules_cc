"""Tests for the CRT and C++ runtime choices delivered by the default MSVC toolchain."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")

_CRT = str(Label("@platforms_contrib//os/windows/crt:preference"))
_CXX = str(Label("//cc/cxx_runtime:preference"))
_PLATFORM = str(Label("//tests/default_windows_toolchain:windows_with_vcredist"))
_TOOLCHAIN = str(Label("//tests/default_windows_toolchain:msvc_cc_toolchain_registration"))

def _expect_crt_flags(flags, no_flags):
    def impl(env, target):
        compile_action = [action for action in target.actions if action.mnemonic == "CppCompile"][0]
        argv = env.expect.that_collection(compile_action.argv)
        for flag in flags:
            argv.contains(flag)
        for flag in no_flags:
            argv.not_contains(flag)

    return impl

def _expect_failure(message):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.contains(message))

    return impl

def msvc_cxx_runtime_tests(name, target):
    tests = []
    for test, settings, impl, expect_failure in [
        ("default", {}, _expect_crt_flags(["/MD"], ["/MT"]), False),
        ("dynamic", {_CRT: ["ucrt"], _CXX: ["msvcp"]}, _expect_crt_flags(["/MD"], ["/MT"]), False),
        ("static", {_CRT: ["static-ucrt"], _CXX: ["static-msvcp"]}, _expect_crt_flags(["/MT"], ["/MD"]), False),
        ("static_crt_only", {_CRT: ["static-ucrt"]}, _expect_crt_flags(["/MT"], ["/MD"]), False),
        ("hybrid", {_CRT: ["ucrt"], _CXX: ["static-msvcp"]}, _expect_crt_flags(["/MT"], ["/MD"]), False),
        ("no_crt", {_CRT: ["none"]}, _expect_crt_flags(["/Zl", "/GS-"], ["/MD", "/MT"]), False),
        ("no_bundled", {_CXX: ["bundled-msvcp"]}, _expect_failure("doesn't define the feature 'bundled_cxx_runtime'"), True),
        ("wrong_crt", {_CRT: ["msvcrt"]}, _expect_failure("targets ucrt, but"), True),
    ]:
        test_name = "{}_{}".format(name, test)
        analysis_test(
            name = test_name,
            target = target,
            impl = impl,
            expect_failure = expect_failure,
            config_settings = {
                "//command_line_option:extra_toolchains": [_TOOLCHAIN],
                "//command_line_option:platforms": [_PLATFORM],
            } | settings,
        )
        tests.append(test_name)

    native.test_suite(name = name, tests = tests)
