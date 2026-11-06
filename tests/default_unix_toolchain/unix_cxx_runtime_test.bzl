"""Tests for the C++ runtime choices delivered by the default Unix toolchain."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")

_LIBC = str(Label("@platforms_contrib//os/linux/libc:preference"))
_CXX = str(Label("//cc/cxx_runtime:preference"))
_PLATFORM = str(Label("//tests/default_unix_toolchain:linux_with_libstdcxx"))
_TOOLCHAIN = str(Label("//tests/default_unix_toolchain:linux_cxx_runtime_cc_toolchain_registration"))

def _link_argv(target):
    return [action for action in target.actions if action.mnemonic == "CppLink"][0].argv

def _expect_flags(flags, no_flags):
    def impl(env, target):
        argv = env.expect.that_collection(_link_argv(target))
        for flag in flags:
            argv.contains(flag)
        for flag in no_flags:
            argv.not_contains(flag)

    return impl

def _expect_compile_flags(flags):
    def impl(env, target):
        compile_action = [action for action in target.actions if action.mnemonic == "CppCompile"][0]
        argv = env.expect.that_collection(compile_action.argv)
        for flag in flags:
            argv.contains(flag)

    return impl

def _expect_failure(message):
    def impl(env, target):
        env.expect.that_target(target).failures().contains_predicate(matching.contains(message))

    return impl

def unix_cxx_runtime_tests(name, target):
    tests = []
    for test, settings, impl, expect_failure in [
        ("default", {}, _expect_flags(["-lstdc++"], ["-l:libstdc++.a", "-static", "-static-libgcc"]), False),
        ("system", {_CXX: ["libstdc++"]}, _expect_flags(["-lstdc++"], ["-l:libstdc++.a"]), False),
        ("static", {_CXX: ["static-libstdc++"]}, _expect_flags(["-l:libstdc++.a", "-static-libgcc"], ["-lstdc++", "-static"]), False),
        ("fully_static", {_LIBC: ["static-glibc"], _CXX: ["static-libstdc++"]}, _expect_flags(["-l:libstdc++.a", "-static"], ["-lstdc++"]), False),
        ("wrong_flavor", {_CXX: ["static-libc++"]}, _expect_failure("doesn't define the feature 'libcxx_runtime'"), True),
        ("no_bundled", {_CXX: ["bundled-libstdc++"]}, _expect_failure("doesn't define the feature 'bundled_cxx_runtime'"), True),
        ("wrong_libc", {_LIBC: ["static-musl"]}, _expect_failure("targets glibc, but"), True),
        ("no_cxx_runtime", {_CXX: ["none"]}, _expect_flags([], ["-lstdc++", "-l:libstdc++.a", "-nostdlib"]), False),
        ("no_cxx_runtime_compile", {_CXX: ["none"]}, _expect_compile_flags(["-nostdinc++"]), False),
        ("no_libc", {_LIBC: ["none"]}, _expect_flags(["-nostdlib", "-static", "-lgcc"], ["-lstdc++", "-l:libstdc++.a", "-static-libgcc"]), False),
        ("no_libc_compile", {_LIBC: ["none"]}, _expect_compile_flags(["-ffreestanding", "-fno-stack-protector", "-nostdinc++"]), False),
        ("no_libc_rejects_cxx_runtime", {_LIBC: ["none"], _CXX: ["static-libstdc++"]}, _expect_failure("can't be used without a libc"), True),
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
