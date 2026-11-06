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

PreferredCxxRuntimeInfo = provider(
    doc = """The result of resolving //cc/cxx_runtime:preference against the target platform.

Provided by //cc/cxx_runtime:preferred.""",
    fields = {
        "diagnostic": "Why no option is viable if `status` is \"unresolved\", otherwise empty. " +
                      "The wording isn't stable.",
        "flavor": "The preferred C++ standard library, currently \"libc++\", \"libstdc++\" or " +
                  "\"msvcp\", or \"none\" if there is none, if `status` is \"resolved\", " +
                  "otherwise None.",
        "linkage": "How the C++ runtime is linked and deployed if `status` is \"resolved\", " +
                   "otherwise None: \"static\" links it into the binary, \"system\" links against " +
                   "the copy on the target platform, \"bundled\" links against a shared copy " +
                   "that's shipped in the runfiles of the binary and \"none\" doesn't use a C++ " +
                   "runtime at all.",
        "status": "\"resolved\" if an option is viable or there is no libc, which rules out a " +
                  "C++ runtime, \"unresolved\" if none is and \"unset\" for an empty ranking, " +
                  "which leaves the choice to the C++ toolchain.",
    },
)

def check_preferred_cxx_runtime(preferred_cxx_runtime):
    """Fails with an actionable error if no C++ runtime option is viable.

    Args:
      preferred_cxx_runtime: The PreferredCxxRuntimeInfo of //cc/cxx_runtime:preferred.

    Returns:
      The given PreferredCxxRuntimeInfo.
    """
    if preferred_cxx_runtime.status == "unresolved":
        fail(preferred_cxx_runtime.diagnostic)
    return preferred_cxx_runtime
