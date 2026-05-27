# VBMeta Patch WebUI

把原来的 `修复vbmeta工具箱.sh` 做成了一个 KernelSU WebUI 模块，核心变化是：

- 不再扫描当前目录里的 `.img`
- 直接从手机的 `by-name` 分区读取源分区和目标分区
- 可以只导出修补后的镜像，也可以在备份后直接回写目标分区

## 当前能力

- 自动检测常见 AVB 相关分区：`vbmeta*`、`boot*`、`init_boot*`、`vendor_boot*`、`recovery*`、`dtbo*`
- 从源分区提取 AVB Header / Footer 中的 VBMeta
- 按目标分区大小重新组装并输出修补镜像
- 可选自动备份目标分区后回写
- WebUI 中显示实时日志与输出文件路径

## 目录结构

- `scripts/backend.sh`: WebUI 调用入口
- `scripts/vbpatch-lib.sh`: 核心修补逻辑
- `webroot/`: KernelSU WebUI 页面
- `build-module.sh`: 打包 zip

## 打包

```bash
chmod +x build-module.sh
./build-module.sh
```

生成文件在 `dist/` 目录下。

## GitHub Actions Release

- 推送标签 `v*`，例如 `v1.0.0`，会自动构建 zip 并创建 GitHub Release
- 也可以在 GitHub Actions 页面手动运行 `Build And Release`，并填写标签名

## 注意

- `patch-file` 子命令主要是为了本地测试核心逻辑，WebUI 实际使用的是分区模式。
- 直接回写目标分区前，建议先用“仅导出镜像”模式验证结果。
