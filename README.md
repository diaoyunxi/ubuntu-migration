# Ubuntu 迁移脚本

英文文件名、两个入口：

- `ubuntu_migration.cmd` — 面向 Windows 10/11 的 Windows CMD 入口。
- `ubuntu_migration_bash.sh` — 面向新 Ubuntu 系统的 Ubuntu Bash 入口。

两个入口均为**全中文输出**，支持**彩色分级日志**，并默认开启
**最详细（DEBUG）级**日志：

- 控制台按级别着色（CMD 用内置 `color` 命令，Bash 用 ANSI 转义序列）；
- 同时把纯文本日志追加到文件，便于事后审计：
  - CMD：`D:\backup\ubuntu_migration_cmd.log`
  - Bash：`/tmp/ubuntu_migration_bash.log`（可用 `LOG_FILE` 覆盖）
- 可用环境变量 `LOG_LEVEL` 调节详细度（可选值 `DEBUG`/`INFO`/`WARN`/
  `ERROR`/`OFF`，默认 `DEBUG` 最详细）。

## 预期工作流

1. 在旧 Windows 机器上：
   - 把本文件夹复制到任意位置，然后运行：

      ```bat
      ubuntu_migration.cmd
      ```

   - 脚本会把自身拷贝到 `D:\backup` 并从那里重新启动。
   - 它会检测带盘符的非 `C:` 固定磁盘。
   - 扫描 `C:\Users\<用户>\` 中疑似用户文件：
     - `Documents`、`Desktop`、`Pictures`、`Music`、`Videos`、`Downloads`
     - `Favorites`、`Saved Games`
     - `AppData\Roaming`（浏览器配置文件、IDE 设置等）
     - 以及 `C:\` 根目录下的散落文件
     - 跳过程序/系统目录（`Windows`、`Program Files`、
       `ProgramData`、`WinSxS`、`Recovery`、`$Recycle.Bin`、
       `AppData\Local\Temp`、`AppData\Local\Packages` 等）。
   - 展示文件清单。默认“全部选中”；按 `E` 用记事本打开清单，
     删除**不想**备份的行，然后保存关闭。
   - 将所选文件复制到 `D:\backup\C`，保留盘相对路径。每次运行都会
     **重新复制并覆盖**同名文件，使备份目录里的文件保持最新；
     但**不会删除**本次未选中的其他已存在备份文件。
   - 从注册表（`HKLM\...\Uninstall`、32 位与 64 位视图、
     `HKCU\...\Uninstall`）及顶层 `Program Files` / `Program Files (x86)`
     文件夹检测已安装应用，并用 `sort /unique` 去重。
   - 展示应用清单。默认“全部选中”；按 `E` 用记事本打开并删除
     不想保留的条目。
   - 对每个选中的应用，会：
     - 写入小写的 `apt_candidates.txt` 条目（名称的 slug），
     - 写入 `snap_candidates.txt` 条目，
     - 尝试对非常常见的应用做内置映射
       （Chrome、VS Code、Zoom、WeChat、Firefox、LibreOffice、VLC）
       映射到真实的 Ubuntu 包名。
     - **重扫后原地去重**：候选清单只会剔除完全重复的行，
       既有的（含你手动添加的）条目一律保留，绝不删除。
   - **ISO 自动下载（幂等）**。步骤 `[8/10]` 会先检查
     `D:\backup` 里是否已有 ISO（优先 `ubuntu-lts.iso`，其次最近修改的
     `*.iso`）：**已有则跳过下载**；只有在完全没有 ISO 时才会自动下载
     当前桌面镜像（3 级回退 `24.04.5.1 → 24.04.4 → 历史裸名`，
     `curl -C -` 断点续传）。官方页面：`https://releases.ubuntu.com/24.04/`
     浏览选择最新的 `*-desktop-amd64.iso`（旧的裸名
     `ubuntu-24.04-desktop-amd64.iso` 已不存在）。如需手动一条命令：
     `curl -L -o "D:\backup\ubuntu-lts.iso" "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso"`
   - 在 UEFI 系统上，会创建一个指向
     `\EFI\Microsoft\Boot\bootmgfw.efi` 的 BCD EFI 项，并把它加到显示
     顺序最前面（尽力而为；见下文限制说明）。
   - 提示制作启动 U 盘并重启。

2. 在新 Ubuntu 系统上：
   - 安装完 Ubuntu 并启动进入系统后，把
     `ubuntu_migration_bash.sh` 从旧磁盘（例如
     `/mnt/windows/backup/app/`）拷出来，或继续放在 `D:\backup`，然后运行：

      ```bash
      sudo bash ./ubuntu_migration_bash.sh
      ```

   - 若检测到安装器/live 会话，它会提示先完成安装并重启，然后退出。
   - 在已安装好的系统里，它会：
     - 用 `blkid` 查找旧的 Windows NTFS/exFAT 盘，
     - 自动挑选包含名为 `backup` 文件夹的那个（大小写不敏感），
       或让用户选择，
     - 确保已安装 `ntfs-3g` / `exfat` 工具，
     - 挂载它，把 `backup/C` 的用户文件还原到
       `~/.ubuntu_migration_backup_C`（通过 `SUDO_USER` 把属主修正为
       真实的非 root 用户），
     - 安装记录在 `backup/app` 下的软件包
       （`apt_candidates.txt` 用 `apt-get`、`snap_candidates.txt` 用
       `snap install`，外加放在那里的任何本地 `.deb` / `.AppImage` /
       `.tar.gz` 文件），
     - 卸载并打印摘要。

## 已知限制

- **从 EFI 直接启动本地 ISO 并不可靠。** 脚本会为
  `\EFI\Microsoft\Boot\bootmgfw.efi` 创建一个 BCD 项并加到显示顺序最前，
  但多数 UEFI 固件**不会**启动本地磁盘上的 ISO 文件。请改用 Rufus
  （或 balenaEtcher）把 `D:\backup\ubuntu-lts.iso` 写入 U 盘，并从 U 盘
  启动。该 BCD 项仅供参考。
- **自动下载应用包依赖 `apt`/`snap`。** CMD 脚本记录候选包名（apt 用
  小写 slug，snap 用原始大小写 slug），外加对少数非常常见应用的内置
  映射。任意的 `.deb`/`.AppImage` 文件**不会**被自动下载；如需额外
  软件，请在重启前手动把 `.deb` / `.AppImage` 文件放入 `D:\backup\app`。
- CMD 脚本刻意保守：避免使用 PowerShell，只用到标准的 `cmd`、`reg`、
  `wmic`（在 `wmic` 不可用时回退到逐盘符探测循环）、`bcdedit` 和 `curl`，
  以及内置的 `color` / `chcp`。
- Bash 脚本需要 `sudo`（直接使用 `mount`/`umount`/`apt-get`），并需要
  `ntfs-3g` 或 `exfat` 工具；缺失时脚本会尝试自动安装。
- CMD 脚本的文件扫描使用 `findstr` 正则，仅匹配“最后一段路径含 1–8 位
  字母数字扩展名”的文件；这是启发式规则，并非完美分类器。
- CMD 脚本逐个复制文件；对非常庞大的目录树（数万文件）可能较慢。
- CMD 脚本以 **GBK(CP936) 编码 + CRLF 换行**保存，并用 `chcp 936` 固定
  代码页，以便在简体中文 Windows 上正确显示中文；若你的系统默认代码页
  不是 936，仍可通过 `chcp` 在脚本开头已设置的 936 正常显示。

## 测试

- `bash tests/run_all.sh` — 运行 CMD 的文本/编码检查与 Bash 的语法检查
  （两者都很快、可移植）。CMD 检查会验证其为合法 GBK(CP936)、CRLF 换行、
  含中文日志标记，并对映射 `findstr` 的 `/C:` 短语保护做回归检查。
- 提供了一份最小 GitHub Actions 工作流
  `.github/workflows/tests.yml`，在每次推送到 `ubuntu-migration/` 文件夹时
  运行同样的检查。
