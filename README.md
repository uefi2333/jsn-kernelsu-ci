# JSN KernelSU CI

华为/荣耀 **JSN**（荣耀 8X / Honor 8X，Kirin 710）内核自动植入 KernelSU 的 GitHub Actions 仓库模板。

> **机型说明**  
> - 代号 `JSN` = 荣耀 8X（Kirin **710**，非 980）  
> - 非 GKI 内核，官方 KernelSU **≥ v1.0 已放弃非 GKI**  
> - 本仓库默认钉 **KernelSU v0.9.5**（最后支持非 GKI 的官方版）  
> - 可选切换 **KernelSU-Next / RKSU**（见 `config.env`）

## 先读：必踩坑清单

| 坑 | 说明 | 本仓库对策 |
|---|---|---|
| 官方 KSU ≥1.0 不支持非 GKI | setup 拉 main 会炸 | 钉 `v0.9.5` 或改用 KSU-Next/RKSU |
| kprobe 在华为内核常坏 | 启用 KPROBES 后 bootloop | 默认 **manual hook**（不依赖 kprobe） |
| manual hook 时勿开 KPROBES | 会误触安全模式（音量减） | defconfig 强制 `CONFIG_KPROBES=n` |
| 内核版本 < 5.9 无 path_umount | 模块 umount 失效 | 自动打 `path_umount` backport |
| defconfig 路径各家不同 | 找不到 config | `config.env` 可改 `DEFCONFIG` |
| 工具链与源码不匹配 | 编不过 / 开机 WiFi 挂 | 默认 AOSP GCC 4.9，可换 clang |
| 刷入错底包内核 | 直接变砖风险 | 产物命名带底包提示，刷前自查 |
| bootloader 未解锁 | 刷不进去 | 华为需非官方解锁，自负风险 |
| 管理器版本不匹配 | 装最新 KSU 管理器识别不了 | 官方分支用 **Manager v0.9.2** |

## 快速开始

1. **Fork / 上传** 本仓库到你的 GitHub。
2. 改 `config.env`：内核源、分支、defconfig、KSU 分支。
3. （可选）仓库 Settings → Secrets → Actions 添加：
   - `GH_TOKEN`：PAT（`repo` 权限），用于推 Release / 拉私有源。
4. Actions → **Build JSN KernelSU** → Run workflow。
5. 产物在 Artifacts / Releases：
   - `Image.gz` / `Image`
   - `AnyKernel3-JSN-*.zip`（有 TWRP 可直接刷）
   - 可选 `boot-repacked.img`（需你提供 stock `boot.img`）

## 配置项（`config.env`）

```bash
KERNEL_URL=https://github.com/Coconutat/android_kernel_huawei_kirin710_KSU
KERNEL_BRANCH=EMUI9.1.0
# 若用未集成 KSU 的纯净源，例如 maimaiguanfan 的 kirin980 或官方开源包，改这里

DEFCONFIG=merge_kirin710_defconfig   # 以源码 arch/arm64/configs 实际文件名为准
ARCH=arm64
SUBARCH=arm64

# kernelsu | kernelsu-next | rksu
KSU_FLAVOR=kernelsu
KSU_VERSION=v0.9.5

# kprobe | manual  （华为建议 manual）
KSU_HOOK=manual

TOOLCHAIN=gcc-4.9                    # gcc-4.9 | aosp-clang
CLANG_VERSION=r383902
ANDROID_VERSION=9

LOCALVERSION=-JSN-KSU
SELINUX_MODE=enforcing               # enforcing | permissive

# 可选：提供 stock boot.img 的 URL，CI 会用 magiskboot 换核打包
STOCK_BOOT_URL=
```

## 工作流做什么

1. Checkout 本仓库 + 浅克隆内核源  
2. 安装依赖与交叉工具链  
3. 按 `KSU_FLAVOR` 执行 `setup.sh` 植入 KernelSU  
4. `KSU_HOOK=manual` 时自动 patch：
   - `fs/exec.c` / `fs/open.c` / `fs/read_write.c` / `fs/stat.c`
   - `drivers/input/input.c`（Safe Mode）
   - `fs/devpts/inode.c`（终端 pm）
   - `fs/namespace.c`（path_umount backport）
5. 写 defconfig：`CONFIG_KSU=y`，manual 时 `CONFIG_KPROBES=n`  
6. 编译 `Image.gz-dtb` / `Image`  
7. 打 AnyKernel3 zip，上传 artifact，可选发 Release  

## 刷入（自担风险）

```bash
# 方式 A：fastboot 刷 boot（需已解锁）
fastboot flash ramdisk boot-repacked.img   # 或对应分区名，华为机型请核对
# 多数 EMUI 是:
fastboot flash kernel Image
# 或整包 boot:
fastboot flash boot boot-repacked.img

# 方式 B：TWRP 刷 AnyKernel3 zip
```

装管理器：

| 分支 | 管理器 |
|---|---|
| KernelSU 官方 v0.9.5 | [KernelSU v0.9.2](https://github.com/tiann/KernelSU/releases/download/v0.9.2/KernelSU_v0.9.2_11682-release.apk) |
| KernelSU-Next | [最新](https://github.com/KernelSU-Next/KernelSU-Next/releases) |
| RKSU | [rsuntk legacy](https://github.com/rsuntk/KernelSU/releases) |

## 推荐内核源（JSN / Kirin 710）

| 源 | 说明 |
|---|---|
| [Coconutat/android_kernel_huawei_kirin710_KSU](https://github.com/Coconutat/android_kernel_huawei_kirin710_KSU) | 已有 KSU 尝试 + Actions 参考，**默认** |
| 华为官方 Kirin 710 开源包 | 纯净，需自己合 KSU |
| [xixiaobei-bei/KernelSU_on_Huawei](https://github.com/xixiaobei-bei/KernelSU_on_Huawei) | 多机型成品参考（含 JSN 相关产物命名习惯） |

> 若你的 JSN 实际是 **Nova 5 / Kirin 980** 变种，把 `KERNEL_URL` 换成  
> `https://github.com/maimaiguanfan/android_kernel_huawei_kirin980` 并改 `DEFCONFIG`。

## Token

不需要把 token 写进仓库。  
在 GitHub → Settings → Secrets and variables → Actions：

- `GH_TOKEN`：`repo` + `workflow`（推 Release / 跨仓 clone 私有源时用）

Workflow 里已用 `${{ secrets.GH_TOKEN || github.token }}`。

## 目录

```
jsn-kernelsu-ci/
├── .github/workflows/build.yml
├── config.env
├── scripts/
│   ├── integrate_ksu.sh
│   ├── apply_manual_hooks.py
│   ├── patch_defconfig.sh
│   ├── build_kernel.sh
│   └── pack_anykernel.sh
├── anykernel/anykernel.sh
├── patches/path_umount.c.fragment
└── README.md
```

## 免责

解锁 / 刷机 / Root 可能导致保修失效、变砖、数据丢失。本仓库仅提供自动化编译模板，后果自负。
