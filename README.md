# pcsc-lite 2.0.3 — CentOS 7 x86_64 动态库 / 静态库

通过 GitHub Actions 在 `centos:7` 容器中原生编译，产出 `libpcsclite.so` + `libpcsclite.a` + 头文件。

## 交付文件

```
.
├── .github/workflows/build-pcsc-lite.yml   # Actions 工作流
├── scripts/build.sh                        # 容器内构建脚本
└── README.md
```

## 使用方法

1. 新建 GitHub 仓库，把这三个文件按上面的结构放进去并推送。
2. 在仓库的 **Actions** 页确认 workflow 已启用。
3. 任选一种触发方式：
   - **手动**：Actions → `Build pcsc-lite 2.0.3 (CentOS 7 x86_64)` → Run workflow（可勾选 libudev / polkit）。
   - **推送**：push 到 `main` / `master`。
   - **打 tag**：推送 `v*` 标签（如 `v2.0.3-build1`），除 Artifact 外还会自动发布 GitHub Release。
4. 运行结束后从 Artifacts 下载 `pcsc-lite-2.0.3-centos7-x86_64`，或直接从 Release 下载压缩包。

## 产物结构

```
dist/
├── include/PCSC/            # winscard.h / wintypes.h / pcsclite.h / ifdhandler.h ...
├── lib/
│   ├── libpcsclite.a        # 静态库
│   ├── libpcsclite.so -> libpcsclite.so.1.0.0
│   ├── libpcsclite.so.1 -> libpcsclite.so.1.0.0
│   ├── libpcsclite.so.1.0.0 # 动态库
│   └── pkgconfig/libpcsclite.pc
├── sbin/pcscd               # 守护进程（附带）
├── BUILD_INFO               # 版本 / configure 参数 / 特性开关
└── SHA256SUMS
```

`pcsc-lite-2.0.3-centos7-x86_64.tar.gz` 是同内容的压缩包，附 `.sha256` 校验文件。

## 集成示例

```bash
# 动态链接
gcc app.c -I./dist/include -L./dist/lib -o app -lpcsclite -lpthread -ldl
LD_LIBRARY_PATH=./dist/lib:$LD_LIBRARY_PATH ./app

# 静态链接
gcc app.c -I./dist/include -o app ./dist/lib/libpcsclite.a -lpthread -ldl -lrt

# 或用 pkg-config（把 dist 拷到目标机的 /usr/local 后）
pkg-config --cflags --libs libpcsclite
```

部署到目标 CentOS 7 时，`cp -a dist/include/* /usr/local/include/`、`cp -a dist/lib/* /usr/local/lib/`，然后 `ldconfig`。

## 可选特性

`libpcsclite` 本身只依赖 pthread，**不需要** libudev / libsystemd / polkit；这些只影响 `pcscd`。默认全关以保证在干净系统上一次编译成功。

| 环境变量 | 作用 | 对应 devel 包 |
|---|---|---|
| `ENABLE_LIBUDEV=1` | pcscd USB 热插拔 | `systemd-devel` |
| `ENABLE_LIBSYSTEMD=1` | pcscd systemd 集成 | `systemd-devel` |
| `ENABLE_POLKIT=1` | pcscd 访问控制 | `polkit-devel` |

手动触发时可在 Run workflow 界面勾选前两项；本地构建直接传环境变量即可。

## 本地构建（可选）

需要可用的 Docker daemon：

```bash
docker run --rm \
  -v "$PWD:/workspace" \
  -e ENABLE_LIBUDEV=0 \
  -w /workspace \
  centos:7 \
  bash scripts/build.sh
```

产物输出到 `./dist/` 和 `./pcsc-lite-2.0.3-centos7-x86_64.tar.gz`。

## 关键实现说明

- **CentOS 7 已 EOL**：官方 mirrorlist 失效，脚本自动把 yum 源切到 `vault.centos.org`。
- **源码缺 autoconf 宏**：GitHub 源码包不含 `m4/`，但 `configure.ac` 用了 `AX_PTHREAD` / `AX_RECURSIVE_EVAL`。脚本从 autoconf-archive 下载这两个宏补齐后再 `autoreconf -fi`。
- **静态库默认关闭**：`configure.ac` 里是 `LT_INIT(disable-static)`，必须显式 `--enable-static`。
- **Actions 兼容性**：`actions/checkout@v4` 基于 Node20，不能在 glibc 2.17 的 CentOS7 容器中运行，所以 checkout 在宿主机 `ubuntu-latest` 上执行，仅编译放进容器。
- **版本选择**：pcsc-lite 2.5.0 起移除了 autotools 改用 meson；2.0.3 仍用 autotools，因此该方案针对 2.0.3 有效。

## 已知限制

- 产物面向 **CentOS 7 / glibc 2.17 / x86_64**，不要拿到更低版本 glibc 的系统上用。
- 默认构建关闭了 pcscd 的 USB 热插拔与 polkit；如需可直接连接读卡器的完整守护进程，请开启对应开关。
- 仅编译库与守护进程，未打包 ccid 读卡器驱动。
