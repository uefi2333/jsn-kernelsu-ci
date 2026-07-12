# AnyKernel3 Ramdisk/Kernel Script for JSN (Honor 8X / Kirin 710)
# shellcheck disable=SC2034
properties() { '
kernel.string=JSN KernelSU CI
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=JSN
device.name2=JSN-L21
device.name3=JSN-L22
device.name4=JSN-L23
device.name5=JSN-L42
device.name6=JSN-AL00
device.name7=JSN-TL00
device.name8=JSN-LX1
supported.versions=
supported.patchlevels=
'; }

block=auto;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

. tools/ak3-core.sh;

## 华为分区差异大：优先 boot，失败再试 kernel 分区名由用户自核
dump_boot;
write_boot;
