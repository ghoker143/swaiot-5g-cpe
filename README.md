# swaiot-5g-cpe

This repository contains the device-specific patch set, configuration, and CI workflow used to build OpenWrt images for a Swaiot 5G CPE based on Qualcomm IPQ807x.

It is designed around the [`JuliusBairaktaris/openwrt-ppe-nss`](https://github.com/JuliusBairaktaris/openwrt-ppe-nss) `ppe-nss` branch (OpenWrt main, kernel 6.18: wired offload via the upstream `qca_ppe`/`qca_edma` drivers, Wi-Fi offload via `nss-wifi-drv`) and exists to add support for the Swaiot hardware on top of that work.

## Acknowledgements

This project builds directly on the work of:

- the OpenWrt project
- [`qosmio/openwrt-ipq`](https://github.com/qosmio/openwrt-ipq), the NSS-enabled base this project was originally built on (dormant since June 2026)
- [`JuliusBairaktaris/openwrt-ppe-nss`](https://github.com/JuliusBairaktaris/openwrt-ppe-nss) and its `nss-packages` feed, the maintained PPE+NSS base this repository now tracks
- the maintainers and contributors of the OpenWrt feeds and packages involved in this build
- Thomas Perrot and participants in the Sierra Wireless forum discussion on EM919x PCIe support, which helped highlight that EM9190/EM919x modules may appear with different PCI enumeration details across batches and hardware variants

Their work makes this repository possible.

## What This Repository Is For

The goal of this repository is simple: provide a reproducible way to build firmware with support for a Swaiot 5G CPE target.

The CI workflow does the following:

1. Clones `JuliusBairaktaris/openwrt-ppe-nss` and adds its NSS firmware feed, pinning the tree to the newest upstream commit the builder CI has published a release for (published = all device groups green, so broken tips are skipped automatically). OPENWRT_COMMIT overrides this.
2. Applies the Swaiot-specific patch series from [`swaiot-patches/`](./swaiot-patches/).
3. Copies the repository [`.config`](./.config) into the OpenWrt build tree.
4. Updates and installs feeds.
5. Runs `make defconfig`, downloads sources, and builds the firmware.

If patch application fails against the latest upstream source, the daily build fails and no firmware artifact is produced for that run.

## SoC Note

The Swaiot M01MX hardware carries an **IPQ8071A** (quad A53, fuse-capped at 1.38 GHz per its speed bin). Earlier revisions of this repository misnamed it IPQ8074; the device tree now uses the `ipq8071-` prefix, while the SoC compatible remains `qcom,ipq8074`, which is the shared binding for all IPQ807x variants.

## Modem Notes

In my own deployment, this target is used with a Sierra Wireless EM9190 modem.

That does **not** mean this repository is universally correct for every Swaiot unit. Hardware revisions, modem batches, firmware versions, board wiring, and PCIe enumeration details may differ.

What may still be useful to others is the overall `ModemManager + QMI + raw-ip` path over the upstream MHI stack. In this setup, that path is working and may serve as a practical reference for people bringing up similar hardware.

Note that the MHI channel configuration used here does not expose the modem's MBIM channels. On the EM9190 firmware batch in my unit (SWIX55C_03.14.10.01), opening the MBIM channel makes the modem switch its QMI WDA data aggregation to MBIM mode until the next modem reset, which breaks unpatched ModemManager QMI connections (`Cannot disable multiplex support`) and is suspected to cause random firmware crashes. Keeping the modem on the plain QMI/raw-ip path avoids both problems.

These findings date from the old (qosmio, kernel 6.12, ModemManager 1.24) base and are marked experimental on the new one: the no-MBIM MHI patch (`0002`) must be re-validated on kernel 6.18 with a current ModemManager, against the stock Foxconn binding, the plain Sierra layout, and a userspace-only alternative (`udev` `ID_MM_PORT_IGNORE` on the MBIM wwan port).

## Important Note About `0002`

[`swaiot-patches/0002-qualcommax-add-EM9190-PCIe-MHI-support-QMI-only-expe.patch`](./swaiot-patches/) includes PCIe/MHI handling that matches my own EM9190 hardware batch.

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
