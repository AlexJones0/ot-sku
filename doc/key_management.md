<!--
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
-->

# Key management and Signing

## Manufacturing

As a brief overview, the provisioning flow is split into the following stages:

 * The unsigned **CP (Chip Probe)** provisioning image is run on the wafer from SRAM, populating a wafer authentication secret and test unlock/exit tokens in OTP -- this step does not tend to vary by SKU.
   The unique CP device ID is then read back from the chip
 * Next comes the **FT (Final Test)** provisioning, which occurs on the packaged chips.
   * The first stage of FT is called **Individualization**, which again runs unsigned from SRAM.
     This configures the FT device ID, creator & owner SW config, public keys for authentication and default boot data in OTP.
     It performs the per-SKU OTP configuration, but does *not* use signed binaries.
   * The last stage of FT is called **Personalization**, which loads *signed* binaries into flash, which are then executed by ROM.
     This stage provisions the OTP `SECRET*` partitions, and stores Key Manager & DICE seeds in flash info pages, setting up the device's identity.
     It generates certificate bodies (`UDS`, `CDI_0` i.e. attestation, `CDI_1` i.e. sealing, and optionally TPM certs) which it then sends to the host, endorsing them with the CA key.
     The device then writes the signed certificates into flash.
     This stage also sets the first owner, installing the owner config & keyring, and erasing relevant owner info.
     For efficiency, this whole stage split into two steps, each of which has its own signed binary:
     * **Flash scrambling** provisions just `SECRET1` and the flash data scrambling config, and is a cut-down loader without extra prints.
     * **Personalize** performs the rest of the flow, as described above.

## Artifacts

There are two types of artifacts that we are interested in signing:

1. **Personalization binaries** (also called "perso" for short).
   These are the binaries described above that are used in manufacturing at the end of the FT (Final Test) stage.
   These might also include extension hooks defined for the SKU.
2. **ROM_EXT**.
   This is the ROM extension that the ROM will boot into after the chip has been provisioned, which will then (try to) boot into `BL0`, the first stage boot.

## Keys

Four classes of key material are defined for the Open Market SKU:

1. **Root keys**, i.e. the Silicon Creator keys.
   These populate the OTP's `ROT_CREATOR_AUTH_CODESIGN` partition and are used to sign ROM_EXT and personalization binaries.
2. **Owner keys**.
   These are verified by the ROM_EXT, and form part of the "owner block".
   They are used to:
   1. Sign the owner configuration block itself.
   2. For ownership transfer: to authorize "unlocking" ownership, so the chip can be handed over, and to authorize activating a new owner configuration after a transfer.
   These are used as part of the owner block, to sign owner firmware and perform ownership transfer.
3. **Application keys**.
   These will live in the owner block's application keyring, and are used to sign the owner's firmware (i.e. `BL0` and anything that comes after it).
   These are hence verified by the ROM_EXT when it tries to boot into BL0.
4. **DICE CA keys**.
   These are used to sign each chip's certificates (UDS, attestation, sealing, etc.) off-device during personalization.
   This is then verified by anybody who wants to check the full DICE attestation chain of the device.

Root, owner and application keys are defined for ECDSA P-256 and SLH-DSA-SHA2-128s signing.
DICE CA keys only use ECDSA P-256.
For root keys, there are 4 separate slots in the OTP `ROT_CREATOR_AUTH_CODESIGN` partition.
These are typically used for 3 `PROD` keys, and one `DEV` key (configured as a `TEST` key type).

## Key Generation

For real releases, keys should be generated and maintained in a Hardware Security Module (HSM) in a secure environment.
Key generation templates can be found in `skus/open/fake_keygen/*/*.json5` files, which can be used with `hsmtool` to generate keys.

For testing the Open Market SKU release flow that is defined in this repository, you can use a local SoftHSM2 instance populated with fake keys.
See the documentation in [`skus/open/fake_keygen`](../skus/open/fake_keygen/README.md) for more information.

***TODO: how should real HSMs handle key rotation? The current key-generation does not support e.g. ID suffixes.***

## Propagating new keys into the SKU

After *any* key generation (fake *or* real), the following manual steps are required to update the Open Market SKU:

1. **Copy the public keys into the Open SKU sub-directories**

```sh
tar -xzf skus/open/fake_keygen/root/root-public.tar.gz               -C skus/open/keys/root
tar -xzf skus/open/fake_keygen/owner/owner-public.tar.gz             -C skus/open/keys/owner
tar -xzf skus/open/fake_keygen/application/application-public.tar.gz -C skus/open/keys/owner
tar -xzf skus/open/fake_keygen/ca/ca-public.tar.gz                   -C skus/open/keys/ca
```

The keysets defined in the `BUILD` files reference these key by name, so no change is needed unless the names of these keys were changed.

2. **Update the root key OTP values in the `ROT_CREATOR_AUTH_CODESIGN` partition**

This is a manual step, since `skus/open/keys/root:root_keys` embeds the root public key material into the OTP, for ROM_EXT / perso validation.
Due to the intricacies in the tooling for generating OTP images, and the format the key material is represented in, it is recommended to use `opentitantool` to recompute these key values:

```sh
# This only covers ECDSA and SLH-DSA keys, since these are the only defined keysets at the time of writing.
for k in skus/open/keys/root/*-ecdsa-*.pub.der; do echo "$k"; opentitantool ecdsa key show "$k"; done
for k in skus/open/keys/root/*-slhdsa-*.pub.pem; do echo "$k"; opentitantool spx key show "$k"; done
```
Taking the values in the `otp_encoded` fields and modifying the `ROT_CREATOR_AUTH_CODESIGN_*_KEY*` items of `skus/open/keys/root:root_keys`.

3. **Regenerate the X.509 Dice CA self-certificate**

This step is only required if you have rotated/generated a CA key.
This step will require you to have `openssl` available with a defined PKCS11 module.
This should be customized as is required -- the below configuration defines a certificate that is valid for centuries, with the standard configuration defined in [`skus/open/keys/ca/dice_ca.conf`](../skus/open/keys/ca/dice_ca.conf).

```sh
# Configure the environment your PKCS11 module, this just uses SoftHSM2 as an example.
source skus/open/fake_keygen/softhsm_sourceme.sh
export PKCS11_MODULE_PATH=${HSMTOOL_MODULE}

# Generate the Dice CA self-certificate
openssl req -new -x509 \
  -config skus/open/keys/ca/dice_ca.conf \
  -engine pkcs11 -keyform engine \
  -key "pkcs11:token=temp;object=nuvoton-ot00-ca-ecdsa-0;type=private?pin-value=123456" \
  -sha256 -days 99999 \
  -out skus/open/keys/ca/dice_ca.pem
```

At this step, it's worth doing some sanity checks to verify the generated certificate:
```sh
# Verify the cert against itself as the trusted CA, to check it is a valid self-signed root cert.
openssl verify -CAfile skus/open/keys/ca/dice_ca.pem skus/open/keys/ca/dice_ca.pem

# Extract the public key from the X.509 cert, and check it matches the public key.
openssl x509 -in skus/open/keys/ca/dice_ca.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | cmp - skus/open/keys/ca/nuvoton-ot00-ca-ecdsa-0.pub.der && echo "key matches"
```

4. **Update the CA key ID in the orchestrator config**

This step is only required if you have rotated/generated a CA key.
**TODO: figure out if this is needed and fill it in. The existing value already looks stale?**

5. **Perform a release**.

At this stage, you can follow the GitHub release flow as documented in [`create_release.md`](./create_release.md) and perform a **signing ceremony** (documented [below](#signing-ceremonies)) to make a release.
The final post-release flow will add commits to the release branch that updates the archives pinned in `extension.bzl` to point to the new release binaries.
A PR can then be made from the release branch to use the release binaries, which will then match the rotated keys.

6. **Verification**.

Check that the signed releases binaries work as intended.
**TODO: come up with a list of tests etc.**

## Signing Ceremonies

As part of the [release flow](./create_release.md), an offline **signing ceremony** is performed between the pre-sign and post-sign steps.
This section documents the practices that should be followed during a signing ceremony.

The ceremony should have at least two participants.
One participant should be the **leader**, who runs the commands to perform the signing operations.
The other participants should be the **witnesses**, who independently verify the actions taken by the leader.

Throughout the ceremony, a log should be maintained (which will be committed under the [`logs/`](../logs/) directory as part of the release).

**TODO: flesh this out a bit more based on existing documents.**

1. **Record ceremony information.**

The date of the signing ceremony, its participants, and a brief description of its purpose (e.g. "ROM_EXT + perso release <tag> for ot00") should be recorded.
The log should also record the `ot-sku` repository used, release branch and full commit, alongside the corresponding `opentitan` repository used, release branch, and full commit (this should be the `OT_REF` written into `release.yml` on the release branch).

2. **Check the pre-signing artifacts**

The pre-signing artifacts should be locally produced, and their hashes should be checked against the pre-sign Github release assets:

```sh
# (From the OpenTitan checkout at `OT_REF`)
bazelisk build --stamp ${BAZEL_OVERRIDE_ARGS} \
  @provisioning_exts//open/perso:presign_perso \
  @provisioning_exts//open/rom_ext:presign_rom_ext \
  //sw/host/hsmtool
sha256sum $(bazelisk cquery --output=files ${BAZEL_OVERRIDE_ARGS} \
  @provisioning_exts//open/perso:presign_perso @provisioning_exts//open/rom_ext:presign_rom_ext)
```

3. **Setup the airgapped environment.**

TODO: copy `hsmtool` and the presigning archives to a staging dir. More discussion on what this environment should look like.

4. **Sign the keys**

TODO: run the provisioning & rom_ext hsmtool signing scripts, as described in the release flow docs:

```
mkdir presign_perso presign_rom_ext
tar -xf presign_perso.tar.xz   -C presign_perso
tar -xf presign_rom_ext.tar.xz -C presign_rom_ext
(cd presign_perso   && $HSMTOOL exec provisioning_ot00.json)
(cd presign_rom_ext && $HSMTOOL exec rom_ext.json)
```

5. **Verify and commit the signatures**

TODO: information on verifying and committing the signatures, some duplication with the release docs.
Before pushing, run the `signature_test` targets locally.
