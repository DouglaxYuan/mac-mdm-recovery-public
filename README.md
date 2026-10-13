# Mac Recovery：保留现有账户的本地配置脚本

在 Apple Silicon 的恢复环境中检查或处理本地注册配置，保留原账户和文件，并提供文件级备份与回滚。

**状态：实验性。** 脚本语法及 macOS 26.6.2 下的只读检查已验证；没有验证本机 macOS 27 Recovery 修改或升级后的实际效果。它处理本地配置，不能解除 Apple 服务端的组织归属，也不处理 Apple Account Activation Lock。

本公开版在运行时输入 Data 卷 UUID 与已有账户短名称，仓库不保存个人账户名或机器卷标识。它不创建同名账户；找不到原账户记录时，修改操作会停止。

## 适用场景

- 保留账户原地升级前，查看原 Data 卷和本地文件状态。
- 已有系统和原账户仍存在，在 Recovery 中按目标卷处理指定配置，或撤销本脚本的一次改动。

抹盘、重建账户或 Data UUID 已改变时，需要重新判断是否适用；创建同名账户不等于恢复原账户。

## 无需登录获取脚本

以下命令把固定版本保存为文件，随后只检查语法；没有自动执行修改：

```bash
curl -fL --connect-timeout 10 --max-time 60 \
  https://raw.githubusercontent.com/DouglaxYuan/mac-mdm-recovery-public/v1.0.0/mdm-preserve-account.sh \
  -o /tmp/mdm-preserve-account.sh
/bin/bash -n /tmp/mdm-preserve-account.sh
```

升级前建议把脚本及本说明另存到 U 盘。若 Recovery 无法联网，可使用离线副本。

## 输入与只读检查

需要准备两项非凭据信息：原 Data 卷 UUID、原账户的短名称。正常系统可用 `id -un` 查看短名称，用 `diskutil info /System/Volumes/Data` 查看 Data 卷 UUID；在 Recovery 中通过磁盘工具或 `diskutil apfs list` 核对原内部 Data 卷。

在 Bash 中输入它们；这些变量不会自动保存到文件，重启后需要重新输入：

```bash
/bin/bash
read -r -p '原 Data 卷 UUID：' MDM_DATA_UUID
read -r -p '现有账户短名称：' MDM_ACCOUNT
export MDM_DATA_UUID MDM_ACCOUNT
/bin/bash /tmp/mdm-preserve-account.sh check
```

`check` 是默认动作，不改文件。它确认目标卷、主目录并显示指定本地配置状态；普通登录环境可能无法确认受保护账户记录，Recovery 修改时会再次核对。

`check` 成功不表示 Recovery 检查或 macOS 27 绕过已成功。不要将本地 `DEP: No / MDM: No` 或网络访问失败视为组织已经释放设备。

## Recovery 中处理配置

1. 先准备可恢复的完整外置备份，保留原账户密码，由你自己完成恢复环境认证。
2. 在 Apple Silicon 上长按电源键进入启动选项，选择“选项 → 继续”。
3. 在磁盘工具中挂载原 Data 卷，需要时自行解锁；不要抹盘。
4. 打开终端，获取脚本、输入参数，并先运行 `check`。
5. 确认目标与修改影响后运行：

```bash
/bin/bash /tmp/mdm-preserve-account.sh apply
```

脚本只允许在已识别的 Recovery 环境修改，并要求交互式输入 `APPLY`。它先备份目标文件，然后处理下表配置；失败时尝试回滚，不自动重启。

| 对象 | 操作 |
|---|---|
| Data 卷 `private/etc/hosts` | 规范三个指定 Apple 注册域名的屏蔽映射，保留其他内容 |
| `.cloudConfigHasActivationRecord`、`.cloudConfigRecordFound` | 备份后删除 |
| `.cloudConfigProfileInstalled`、`.cloudConfigRecordNotFound` | 不存在时创建 |
| 账户、密码、主目录 | 不修改 |

四个标记位于 Data 卷 `private/var/db/ConfigurationProfiles/Settings/`。脚本不关闭 SIP、不改 launchd、不创建用户、不修改 `.AppleSetupDone`。

成功信息仅表示本地文件修改与检查完成。记下脚本输出的备份目录，重启后核对原账户、数据、应用及联网状态；如果仍要求注册，不要把报错当成功或反复扩大修改范围。

## 回滚

重新进入 Recovery，挂载同一 Data 卷，重新设置上述两个输入变量。输入 apply 实际输出的备份目录：

```bash
read -r -p '本次备份目录完整路径：' mdm_backup_dir
/bin/bash /tmp/mdm-preserve-account.sh restore "$mdm_backup_dir"
```

手动输入 `RESTORE` 后，只恢复整个 hosts 和四个标记；备份之后对这些文件的其他修改也会被覆盖。它不能回退 macOS、恢复被抹掉的账户或解除服务端组织归属。卷内备份不能代替完整外置备份。

## 停止条件与反馈

目标 UUID 不符、原账户缺失、卷未挂载/未解锁、Recovery 条件不符、目标目录改变或备份失败时，停止并保留错误文字。不要删除脚本中的校验来继续。

可在本仓库 [Issues](https://github.com/DouglaxYuan/mac-mdm-recovery-public/issues) 提交系统版本、报错及环境说明。不要上传账户数据库、口令、实际 hosts、原始日志或机器备份。隐私边界见 [SECURITY.md](SECURITY.md)。

## 来源与版本

- [脚本](mdm-preserve-account.sh)
- [来源与许可状态](SOURCES.md)
- [版本记录](CHANGELOG.md)

公开源码用于查看与个人设备操作参考；原材料许可未确认，因此没有将其标为采用 MIT 等开源许可证。

## English summary

Experimental Apple Silicon Recovery helper that preserves an existing account and checks or changes a limited set of local enrollment files. The public version requires the original Data volume UUID and account short name at runtime and contains no machine-specific defaults. `check` is read-only; `apply` and `restore` require Recovery and interactive confirmation. macOS 27 behavior has not been verified on the target machine. Local file changes do not release an organization assignment or remove Activation Lock.
