# Sonosystem Toolchain Repository

This repository stores **prebuilt toolchains, third-party libraries, and binary SDKs** required by Wosler's Sonosystem software projects.  
It is used to improve reliability and significantly reduce CI build times by providing stable, versioned toolchain artifacts.

---

## 📦 What Goes in This Repository?

This repo is intended as a **centralized binary/toolchain storage location** for:

- Prebuilt **Qt** versions (Windows & Linux)
- Other third-party libraries that are:
  - Expensive to compile
  - Not available through apt/pacman/msys2/vcpkg
  - Need exact version pinning
- Internal build toolchains or C++ SDKs
- CI dependency bundles

Artifacts are uploaded via **GitHub Releases**, one release per toolchain or version.

---

## 🏷 Repository Structure
README.md - This file
/ (no source code store here; binaries managed via Releases)

Most binaries (zip/tar.gz) **should NOT be committed to the repository**.
Instead, store toolchains in **GitHub Releases** associated with tags like:

- `qt-6.10.0`
- `opencv-4.9.0`
- `ffmpeg-6.0-windows`
- `sonosystem-sdk-v1`

---

## 🚀 How to Upload Toolchains (Quick Guide)

1. Build or collect the required toolchain/library.
2. Package it (e.g., `.tar.gz` for Linux, `.zip` for Windows).
3. Create a GitHub Release (via UI or CLI).
4. Attach the binary as an asset.
5. Reference the download URL from CI or setup scripts.

Example download URL format:
https://github.com/Wosler-Corp/sonosystem-toolchain/releases/download/<TAG>/<FILE>

---

## 🛠 How CI Should Use This Repo

### Linux example:
```bash
curl -L \
  https://github.com/Wosler-Corp/sonosystem-toolchain/releases/download/qt-5.15.2/qt-5.15.2-linux-gcc13.tar.gz \
  -o qt.tar.gz
sudo tar -xzf qt.tar.gz -C /opt
```

### Windows example:
```powershell
Invoke-WebRequest `
  https://github.com/Wosler-Corp/sonosystem-toolchain/releases/download/qt-5.15.2/qt-5.15.2-windows-msvc2019_64.zip `
  -OutFile qt.zip
Expand-Archive qt.zip -DestinationPath C:\Qt
```
