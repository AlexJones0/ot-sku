# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _hub_repo_impl(rctx):
    for folder_name, spoke_file in rctx.attr.repo_mapping.items():
        # Get the absolute path to the spoke repository's root
        # using the label of a file in the root of the spoke repository.
        spoke_path = rctx.path(spoke_file).dirname

        # Symlink the entire spoke repo to a top-level folder in the hub
        rctx.symlink(spoke_path, folder_name)

    # Create a root BUILD file so Bazel recognizes these as packages
    rctx.file("BUILD.bazel", "# Hub Root")

hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {"repo_mapping": attr.string_keyed_label_dict(
        doc = "Map hub symlink names to spoke repositories.  The spoke repo should be the label of a file in the root of the spoke repo (e.g. BUILD.bazel)",
    )},
)

# Important note: this dictionary is read and modified by the release script (script/release.py).
# Therefore, it needs to remain a constant dictionary which can be parsed by the python ast module.
_ARCHIVES = {
    "presign_rom_ext": {
        "url": "https://github.com/AlexJones0/ot-sku/releases/download/test-release-slh-dsa-2/presign_rom_ext.tar.xz",
        "sha256": "5d59840d387cd33a47b45a263640c00b4260c2ebd8f6216e52b49a7eebf4f288",
    },
    "presign_perso": {
        "url": "https://github.com/AlexJones0/ot-sku/releases/download/test-release-slh-dsa-2/presign_perso.tar.xz",
        "sha256": "5fd373330a0af0175f4ace0452b73e862bac0bdee4ccd191c729408b54835c12",
    },
}

def _extra_impl(mctx):
    for (name, info) in _ARCHIVES.items():
        http_archive(
            name = name,
            **info
        )
    hub_repo(
        name = "provisioning_exts_extra",
        repo_mapping = {
            name: "@{}//:BUILD.bazel".format(name)
            for name in _ARCHIVES
        },
    )

extra = module_extension(
    implementation = _extra_impl,
)
