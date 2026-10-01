# CP210x external-prerequisite evidence

Decision: CP210x is an external hardware-development prerequisite. It is not a distributable toolchain package or a member of either package profile.

Evidence checked on 2026-09-29:

- The recorded archive URL was `https://www.silabs.com/documents/public/software/CP210x_Windows_Drivers.zip`.
- A direct request from the Windows staging PC returned `Access Denied`. No archive, bundled license, version, digest, or signature evidence was obtained.
- The official product page, `https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers`, identifies the CP210x VCP drivers but does not grant standalone third-party redistribution rights.
- The official Silicon Labs Master Software License Agreement was version `20260804`: `https://www.silabs.com/about-us/legal/master-software-license-agreement`.
- MSLA sections 4.1.6 and 4.2.5 permit external distribution only when the licensed program is incorporated into an Authorized Application. Section 5 prohibits uses not expressly authorized and restricts transfer and distribution. These terms do not clearly permit publishing the unmodified Windows driver as a standalone Wosler release asset.

Consequences:

- Do not create a CP210x package definition, license tree, staged ZIP, catalog asset, cache entry, mirror, or automated vendor-download fallback.
- Developer preflight remains separate from package installation and may only detect a signed installed driver and provide Windows Update or official manual-install guidance.
- Hardware-in-the-loop machines require one-time external driver provisioning.
- Explicit Silicon Labs permission or other accepted redistribution evidence is required before reconsidering redistribution.
