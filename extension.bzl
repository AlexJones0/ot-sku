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
        "url": "https://github.com/AlexJones0/ot-sku/releases/download/test-release-slh-dsa-5/presign_rom_ext.tar.xz",
        "sha256": "08affc86809023cd5ad433e1438ee8d3c0b8387ac356651faaf18a382cc1836b",
    },
    "presign_perso": {
        "url": "https://github.com/AlexJones0/ot-sku/releases/download/test-release-slh-dsa-5/presign_perso.tar.xz",
        "sha256": "bfa77628baf6940222c2dab0ead10219ea95d70b23723f86b57c89f195423c5f",
    },
    "rom_ext_release": {
        "url": "https://github.com/AlexJones0/ot-sku/releases/download/test-release-slh-dsa-5-final/rom_ext_release.tar.xz",
        "sha256": "2be5b5a44234311453a9b92d9666c6e2327b1f2358598a981ce7b2497664b74e",
    },
    "perso_release": {
        "url": "https://github.com/AlexJones0/ot-sku/releases/download/test-release-slh-dsa-5-final/perso_release.tar.xz",
        "sha256": "34eda6824c2e785e07a812b5d982f5a530d30969069fbc0a081f79844249a0eb",
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
