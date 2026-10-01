# External Windows prerequisites

## Visual Studio 2022

Visual Studio 2022 is retained as a licensed external prerequisite. Its stable major version, generator, toolset and component contract are enforced; mutable patch versions are observed as evidence but are not pinned. Microsoft’s signed bootstrapper is used only when VS2022 is absent and is never redistributed.

The catalog accepts any Visual Studio 2022 product in `[17.0,18.0)` that is complete, launchable, and provides the four declared MSBuild, CMake, x64 C++ tool, and current VC runtime components. Detection uses `vswhere` with all products. Existing Build Tools, Community, Professional, and Enterprise installations are equivalent when they satisfy that component contract. The detected product ID, installation version/path, default VC tools version, `cl.exe /Bv`, MSBuild version, CMake generator, and selected Windows SDK are evidence only.

When no matching installation exists, setup may download `https://aka.ms/vs/17/release/vs_BuildTools.exe` to a temporary directory as the explicit licensed-vendor exception. It must reject any invalid or non-Microsoft Authenticode signature before execution, add only the declared component IDs, accept only success or reboot-required success, repeat the exact detection, and delete the temporary bootstrapper. No Microsoft installer, layout, Build Tools payload, or extracted Microsoft file is a Wosler package or release asset. MinGW-only developer setup does not invoke this prerequisite.

## CP210x hardware driver

CP210x is not a distributable toolchain package. Both Windows package profiles contain the same seven redistributable units; installing a profile does not provision a driver.

The later developer preflight must detect an installed, validly signed Silicon Labs CP210x driver and accept the current `silabser.inf` and legacy `slabvcp.inf` names. An absent driver must produce guidance to connect the hardware and use Windows Update, plus a link to the [official Silicon Labs CP210x driver page](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers) for manual provisioning. Do not automatically download, mirror, cache, redistribute, or install the driver. Provision the HIL machine once through that external path.

The 2026-09-29 acquisition attempt returned Access Denied. The Silicon Labs MSLA did not establish permission to publish a standalone driver release asset. The exact URLs, agreement version, and relevant sections are preserved in [the redistribution evidence](cp210x-external-prerequisite-evidence.md); this external-prerequisite decision does not resolve redistribution rights. This document specifies later preflight behavior, not an implemented driver detector.
