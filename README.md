# swaiot-5g-cpe

This repository contains the device-specific patch set, configuration, and CI workflow used to build OpenWrt images for a Swaiot 5G CPE based on Qualcomm IPQ807x.

It is designed around the [`qosmio/openwrt-ipq`](https://github.com/qosmio/openwrt-ipq) `main-nss` branch and exists to add support for the Swaiot hardware on top of that upstream work.

## Acknowledgements

This project builds directly on the work of:

- the OpenWrt project
- [`qosmio/openwrt-ipq`](https://github.com/qosmio/openwrt-ipq), which provides the NSS-enabled Qualcomm IPQ807x/IPQ60xx OpenWrt base used here
- the maintainers and contributors of the OpenWrt feeds and packages involved in this build
- Thomas Perrot and participants in the Sierra Wireless forum discussion on EM919x PCIe support, which helped highlight that EM9190/EM919x modules may appear with different PCI enumeration details across batches and hardware variants

Their work makes this repository possible.

## What This Repository Is For

The goal of this repository is simple: provide a reproducible way to build firmware with support for a Swaiot 5G CPE target.

The CI workflow does the following:

1. Clones `qosmio/openwrt-ipq` from the `main-nss` branch.
2. Applies the Swaiot-specific patch series from [`swaiot-patches/`](./swaiot-patches/).
3. Copies the repository [`.config`](./.config) into the OpenWrt build tree.
4. Updates and installs feeds.
5. Installs the ModemManager feed patch required by this setup.
6. Runs `make defconfig`, downloads sources, and builds the firmware.

If patch application fails against the latest upstream source, the daily build fails and no firmware artifact is produced for that run.

## Modem Notes

In my own deployment, this target is used with a Sierra Wireless EM9190 modem.

That does **not** mean this repository is universally correct for every Swaiot unit. Hardware revisions, modem batches, firmware versions, board wiring, and PCIe enumeration details may differ.

What may still be useful to others is the overall `ModemManager + QMI + multiplexing` path. In this setup, that path is working and may serve as a practical reference for people bringing up similar hardware.

## Important Note About `0004`

[`swaiot-patches/0004-qualcommax-add-support-for-Sierra-EM9190-via-PCIe-MH.patch`](./swaiot-patches/0004-qualcommax-add-support-for-Sierra-EM9190-via-PCIe-MH.patch) includes PCIe/MHI handling that matches my own EM9190 hardware batch.

That part should be treated as **hardware-specific**, not as a universal EM9190 solution.

Even if someone is using the same modem model name, their module may expose different PCI IDs or behave differently depending on production batch, firmware, carrier variant, or platform integration. Please verify those details on your own hardware before reusing that patch as-is.

The Sierra Wireless forum thread on EM919x PCIe support was especially useful here because it documents a case where an engineering-sample EM919x exposed different subsystem identifiers, reinforcing the point that PCI enumeration details are not guaranteed to be identical across all modules that share the same product name:

https://forum.sierrawireless.com/t/sierra-wireless-airprime-em919x-pcie-support/24927

## License

This repository is released under **GPL-2.0-only**.

At the same time, this repository is built around upstream OpenWrt-derived source trees and contains patches intended to be applied to upstream code. Because of that, a practical compatibility rule applies:

- if an upstream file, component, or subtree carries a more specific license notice, SPDX identifier, or copyright statement, that upstream statement takes precedence for the relevant derived work
- third-party packages and feed content keep their own original licenses
- this repository-level license statement should be read as a project-wide default, not as an override of more specific upstream licensing terms

In short: **GPL-2.0-only by default here, but where upstream provides a more specific licensing statement, upstream governs that part.**
