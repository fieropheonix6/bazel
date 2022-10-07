# Copyright 2020 The Bazel Authors. All rights reserved.
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

"""Builds the Objective-C provider"""

objc_internal = _builtins.internal.objc_internal
CcInfo = _builtins.toplevel.CcInfo
apple_common = _builtins.toplevel.apple_common

def _create_context_and_provider(
        ctx,
        compilation_attributes,
        compilation_artifacts,
        intermediate_artifacts,
        alwayslink,
        has_module_map,
        extra_import_libraries,
        deps,
        runtime_deps,
        linkopts):
    objc_providers = []
    cc_compilation_contexts = []
    cc_linking_contexts = []

    # List of CcLinkingContext to be merged into ObjcProvider, to be done for
    # deps that don't have ObjcProviders.  TODO(waltl): remove after objc link
    # info migration.
    cc_linking_contexts_for_merging = []
    for dep in deps:
        if apple_common.Objc in dep:
            objc_providers.append(dep[apple_common.Objc])
        elif CcInfo in dep:
            # We only use CcInfo's linking info if there is no ObjcProvider.
            # This is required so that objc_library archives do not get treated
            # as if they are from cc targets.
            cc_linking_contexts_for_merging.append(dep[CcInfo].linking_context)

        if CcInfo in dep:
            cc_compilation_contexts.append(dep[CcInfo].compilation_context)
            cc_linking_contexts.append(dep[CcInfo].linking_context)

    runtime_objc_providers = []
    for runtime_dep in runtime_deps:
        if apple_common.Objc in runtime_dep:
            runtime_objc_providers.append(runtime_dep[apple_common.Objc])
        if CcInfo in runtime_dep:
            cc_compilation_contexts.append(runtime_dep[CcInfo].compilation_context)

    link_order_keys = [
        "imported_library",
        "cc_library",
        "library",
        "force_load_library",
        "linkopt",
    ]
    objc_provider_kwargs = {
        "imported_library": [depset(direct = extra_import_libraries, order = "topological")],
        "weak_sdk_framework": [],
        "sdk_dylib": [],
        "linkopt": [],
        "library": [],
        "providers": objc_providers,
        "cc_library": [],
        "sdk_framework": [],
        "linkstamp": [],
        "force_load_library": [],
        "umbrella_header": [],
        "module_map": [],
        "source": [],
    }

    objc_compilation_context_kwargs = {
        "providers": objc_providers + runtime_objc_providers,
        "cc_compilation_contexts": cc_compilation_contexts,
        "public_hdrs": [],
        "private_hdrs": [],
        "public_textual_hdrs": [],
        "defines": [],
        "includes": [],
    }

    for cc_linking_context in cc_linking_contexts_for_merging:
        link_opts = []
        libraries_to_link = []
        for linker_input in cc_linking_context.linker_inputs.to_list():
            link_opts.extend(linker_input.user_link_flags)
            libraries_to_link.extend(linker_input.libraries)
        _add_linkopts(objc_provider_kwargs, link_opts)

        objc_provider_kwargs["cc_library"].append(
            depset(direct = libraries_to_link, order = "topological"),
        )

    _add_linkopts(
        objc_provider_kwargs,
        objc_internal.expand_toolchain_and_ctx_variables(ctx = ctx, flags = linkopts),
    )

    # Temporary solution to specially handle linkstamps, so that they don't get
    # dropped.  When linking info has been fully migrated to CcInfo, we can
    # drop this.
    for cc_linking_context in cc_linking_contexts:
        objc_provider_kwargs["linkstamp"].extend(cc_linking_context.linkstamps().to_list())

    if compilation_attributes != None:
        sdk_dir = apple_common.apple_toolchain().sdk_dir()
        usr_include_dir = sdk_dir + "/usr/include/"
        sdk_includes = []

        for sdk_include in compilation_attributes.sdk_includes.to_list():
            sdk_includes.append(usr_include_dir + sdk_include)

        objc_provider_kwargs["sdk_framework"].extend(
            compilation_attributes.sdk_frameworks.to_list(),
        )
        objc_provider_kwargs["weak_sdk_framework"].extend(
            compilation_attributes.weak_sdk_frameworks.to_list(),
        )
        objc_provider_kwargs["sdk_dylib"].extend(compilation_attributes.sdk_dylibs.to_list())
        objc_compilation_context_kwargs["public_hdrs"].extend(compilation_attributes.hdrs.to_list())
        objc_compilation_context_kwargs["public_textual_hdrs"].extend(
            compilation_attributes.textual_hdrs.to_list(),
        )
        objc_compilation_context_kwargs["defines"].extend(compilation_attributes.defines)
        objc_compilation_context_kwargs["includes"].extend(
            compilation_attributes.header_search_paths(
                genfiles_dir = ctx.genfiles_dir.path,
            ).to_list(),
        )
        objc_compilation_context_kwargs["includes"].extend(sdk_includes)

    if compilation_artifacts != None:
        all_sources = []
        all_sources.extend(compilation_artifacts.srcs)
        all_sources.extend(compilation_artifacts.non_arc_srcs)
        all_sources.extend(compilation_artifacts.private_hdrs)

        if compilation_artifacts.archive != None:
            objc_provider_kwargs["library"] = [
                depset([compilation_artifacts.archive], order = "topological"),
            ]
        objc_provider_kwargs["source"].extend(all_sources)

        objc_compilation_context_kwargs["public_hdrs"].extend(
            compilation_artifacts.additional_hdrs.to_list(),
        )
        objc_compilation_context_kwargs["private_hdrs"].extend(compilation_artifacts.private_hdrs)

        uses_cpp = False
        arc_and_non_arc_srcs = []
        arc_and_non_arc_srcs.extend(compilation_artifacts.srcs)
        arc_and_non_arc_srcs.extend(compilation_artifacts.non_arc_srcs)
        for source_file in arc_and_non_arc_srcs:
            uses_cpp = uses_cpp or _is_cpp_source(source_file)

        if uses_cpp:
            objc_provider_kwargs["flag"] = ["uses_cpp"]

    if alwayslink:
        direct = []
        if compilation_artifacts != None:
            if compilation_artifacts.archive != None:
                direct.append(compilation_artifacts.archive)

        direct.extend(extra_import_libraries)

        objc_provider_kwargs["force_load_library"] = [
            depset(
                direct = direct,
                transitive = objc_provider_kwargs["force_load_library"],
                order = "topological",
            ),
        ]

    if has_module_map:
        module_map = intermediate_artifacts.swift_module_map
        umbrella_header = module_map.umbrella_header()
        if umbrella_header != None:
            objc_provider_kwargs["umbrella_header"].append(umbrella_header)

        objc_provider_kwargs["module_map"].append(module_map.file())

    objc_provider_kwargs_built = {}
    for k, v in objc_provider_kwargs.items():
        if k == "providers":
            objc_provider_kwargs_built[k] = v
        elif k in link_order_keys:
            objc_provider_kwargs_built[k] = depset(transitive = v, order = "topological")
        else:
            objc_provider_kwargs_built[k] = depset(v)

    objc_compilation_context = objc_internal.create_compilation_context(
        **objc_compilation_context_kwargs
    )

    return (
        apple_common.new_objc_provider(**objc_provider_kwargs_built),
        objc_compilation_context,
        cc_linking_contexts,
    )

def _is_cpp_source(source_file):
    return source_file.extension in ["cc", "cpp", "mm", "cxx", "C"]

def _add_linkopts(objc_provider_kwargs, link_opts):
    framework_link_opts = {}
    non_framework_link_opts = []
    i = 0
    skip_next = False
    for arg in link_opts:
        if skip_next:
            skip_next = False
            i += 1
            continue
        if arg == "-framework" and i < len(link_opts) - 1:
            framework_link_opts[link_opts[i + 1]] = True
            skip_next = True
        else:
            non_framework_link_opts.append(arg)
        i += 1

    objc_provider_kwargs["sdk_framework"].extend(framework_link_opts.keys())
    objc_provider_kwargs["linkopt"].append(
        depset(
            direct = non_framework_link_opts,
            order = "topological",
        ),
    )

objc_common = struct(
    create_context_and_provider = _create_context_and_provider,
)
