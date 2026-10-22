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

"""Maps platform-independent shared library ABI attributes to the target's binary format."""

load("//cc/common:cc_common.bzl", "cc_common")
load("//cc/common:cc_helper.bzl", "artifact_category")
load("//cc/common:feature_names.bzl", "feature_names")

_SONAME_FEATURES = ["set_soname", "set_install_name", "_soname_flags"]

# Mach-O packs versions as X[.Y[.Z]] into 32 bits.
_MACHO_VERSION_LIMITS = [65535, 255, 255]

def _check_name(name, attr):
    if not name or "/" in name or "\\" in name:
        fail("'{}' must be a non-empty file name without directories".format(name), attr = attr)

def _check_soversion(soversion):
    if not all([part.isdigit() for part in soversion.split(".")]):
        fail("'{}' must consist of dot-separated numbers".format(soversion), attr = "soversion")

def _macho_version(version, attr):
    parts = version.split(".")
    if (len(parts) > 3 or not all([part.isdigit() for part in parts]) or
        any([int(part) > limit for part, limit in zip(parts, _MACHO_VERSION_LIMITS)])):
        fail(
            "'{}' can't be used as a Mach-O version, which has the form X[.Y[.Z]] with X <= 65535 and Y, Z <= 255".format(version),
            attr = attr,
        )
    return version

def shared_library_abi(
        *,
        label,
        shared_lib_name,
        library_name,
        soversion,
        version,
        darwin_versions,
        dll_name,
        version_script,
        exported_symbols_list,
        shared_library_format,
        feature_configuration,
        cc_toolchain):
    """Derives the platform-specific file name and link flags of a shared library.

    Args:
        label: (Label) The label of the target.
        shared_lib_name: (str) An explicit file name that overrides all naming attributes.
        library_name: (str) The base name of the library, defaults to the target name.
        soversion: (str) The ABI version, may be empty.
        version: (str) The full version, may be empty.
        darwin_versions: (list[str]) Explicit Mach-O compatibility and current version, may be empty.
        dll_name: (str) The base name of the DLL on Windows, may be empty.
        version_script: (File|None) An ELF version script.
        exported_symbols_list: (File|None) A Mach-O exported symbols list.
        shared_library_format: (str) The value of SharedLibraryFormatInfo.format.
        feature_configuration: The feature configuration of the link.
        cc_toolchain: The C++ toolchain.

    Returns:
        A struct with the fields basename (the file name of the library or None to keep the
        toolchain's default), link_name (the unversioned file name for packaging or None),
        user_link_flags and additional_inputs.
    """
    if shared_lib_name and (library_name or soversion or dll_name):
        fail("shared_lib_name can't be combined with library_name, soversion or dll_name", attr = "shared_lib_name")
    if library_name:
        _check_name(library_name, "library_name")
    if soversion:
        _check_soversion(soversion)
    if dll_name:
        _check_name(dll_name, "dll_name")
    name = library_name or label.name

    basename = shared_lib_name or None
    link_name = None
    user_link_flags = []
    additional_inputs = []

    if feature_configuration.is_enabled(feature_names.TARGETS_WINDOWS):
        if dll_name:
            basename = (dll_name[:-len(".dll")] if dll_name.lower().endswith(".dll") else dll_name) + ".dll"
        elif library_name:
            basename = cc_common.get_artifact_name_for_category(
                cc_toolchain = cc_toolchain,
                category = artifact_category.DYNAMIC_LIBRARY,
                output_name = name,
            )
    elif shared_library_format == "macho":
        if library_name or soversion:
            basename = "lib{}{}.dylib".format(name, "." + soversion if soversion else "")
            if soversion:
                link_name = "lib{}.dylib".format(name)
            if not any([feature_configuration.is_enabled(f) for f in _SONAME_FEATURES]):
                user_link_flags.append("-Wl,-install_name,@rpath/" + basename)
        if darwin_versions:
            if len(darwin_versions) != 2:
                fail("must contain the compatibility and the current version", attr = "darwin_versions")
            compatibility_version = _macho_version(darwin_versions[0], "darwin_versions")
            current_version = _macho_version(darwin_versions[1], "darwin_versions")
        else:
            compatibility_version = _macho_version(soversion, "soversion") if soversion else None
            current_version = _macho_version(version, "version") if version else None
        if compatibility_version:
            user_link_flags.append("-Wl,-compatibility_version," + compatibility_version)
        if current_version:
            user_link_flags.append("-Wl,-current_version," + current_version)
        if exported_symbols_list:
            user_link_flags.append("-Wl,-exported_symbols_list," + exported_symbols_list.path)
            additional_inputs.append(exported_symbols_list)
    elif shared_library_format in ("elf", "elf_unversioned"):
        # Android only loads and packages unversioned lib<name>.so files.
        if shared_library_format == "elf_unversioned":
            soversion = ""
        if library_name or soversion:
            basename = "lib{}.so{}".format(name, "." + soversion if soversion else "")
            if soversion:
                link_name = "lib{}.so".format(name)
            if not feature_configuration.is_enabled(feature_names.SET_SONAME):
                user_link_flags.append("-Wl,-soname," + basename)
        if version_script:
            user_link_flags.append("-Wl,--version-script=" + version_script.path)
            additional_inputs.append(version_script)

    return struct(
        basename = basename,
        link_name = link_name,
        user_link_flags = user_link_flags,
        additional_inputs = additional_inputs,
    )
