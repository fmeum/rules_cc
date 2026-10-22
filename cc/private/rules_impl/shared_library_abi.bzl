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

"""Platform-independent attributes describing the ABI of a shared library."""

SharedLibraryFormatInfo = provider(
    doc = "The binary format of shared libraries on the target platform, except for COFF, " +
          "which is detected through the toolchain's targets_windows feature.",
    fields = {"format": "One of 'elf', 'elf_unversioned' (Android), 'macho' or 'other'."},
)

def _shared_library_format_impl(ctx):
    return [SharedLibraryFormatInfo(format = ctx.attr.format)]

shared_library_format = rule(
    implementation = _shared_library_format_impl,
    attrs = {"format": attr.string(values = ["elf", "elf_unversioned", "macho", "other"])},
)

SHARED_LIBRARY_ABI_ATTRS = {
    "library_name": attr.string(doc = """
The base name of the shared library, from which its platform-specific file name is derived (e.g.
<code>z</code> for <code>libz.so.1</code>, <code>libz.1.dylib</code> and <code>z.dll</code> or
<code>libz.dll</code>). Defaults to the name of the target."""),
    "soversion": attr.string(doc = """
The ABI version of the shared library, which changes whenever the library breaks binary
compatibility. Should match upstream's choice so that prebuilt binaries can load the library.
<ul>
<li>ELF: the library is named and its SONAME set to <code>lib&lt;name&gt;.so.&lt;soversion&gt;</code>.
</li>
<li>Mach-O: the library is named <code>lib&lt;name&gt;.&lt;soversion&gt;.dylib</code> and its
compatibility version is set to <code>soversion</code>.</li>
<li>Windows: not used, see <code>dll_name</code>.</li>
</ul>
The unversioned name (<code>lib&lt;name&gt;.so</code>, <code>lib&lt;name&gt;.dylib</code>) is
provided as a symlink in the <code>link_name</code> output group for packaging."""),
    "version": attr.string(doc = """
The full version of the library (e.g. <code>1.3.2</code>). Used as the Mach-O current version."""),
    "darwin_versions": attr.string_list(doc = """
The Mach-O compatibility and current version, if they differ from <code>soversion</code> and
<code>version</code>, e.g. because upstream's libtool build derives them from its own version info.
A dylib can only be loaded by binaries whose recorded compatibility version is at most its own
current version."""),
    "dll_name": attr.string(doc = """
The base name of the DLL on Windows if it differs from the toolchain's default
(<code>&lt;name&gt;.dll</code> with MSVC, <code>lib&lt;name&gt;.dll</code> with MinGW), e.g.
<code>zlib1</code>. If <code>win_def_file</code> has a <code>LIBRARY</code> statement, it must
match."""),
    "version_script": attr.label(allow_single_file = True, doc = """
A linker version script that is passed to the linker when targeting an ELF platform and ignored
otherwise."""),
    "exported_symbols_list": attr.label(allow_single_file = True, doc = """
A file with the (mangled) names of the symbols to export, one per line, that is passed to the
linker when targeting a Mach-O platform and ignored otherwise."""),
}
