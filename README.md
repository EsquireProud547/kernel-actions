# kernel-actions

编译自定义 Linux 内核并打包为 .deb

> 参考：<https://github.com/byJoey/Actions-bbr-v3>

---

## 🚀 如何使用

1. **Fork 本仓库**
2. **修改内核配置**：将 `kernel.config` 修改为你的自定义内核配置
3. **执行工作流**：运行 GitHub Actions 工作流，等待构建成功
4. **配置安装脚本**：编辑 `install.sh`，修改 `GITHUB_REPO` 变量为你的仓库名：
   ```bash
   GITHUB_REPO="你的用户名/你的仓库名"
   ```
5. **运行安装**：在目标服务器上执行安装脚本

---

## ⚙️ 构建系统配置

构建系统支持通过仓库根目录的三个文本文件自定义内核配置：

### 1. `disabled_kernel_configs.txt` - 禁用不需要的功能

格式示例：
```
CONFIG_DEBUG_KERNEL
CONFIG_DEBUG_FS
CONFIG_KGDB
```

### 2. `enabled_kernel_configs.txt` - 启用特定功能

格式示例：
```
CONFIG_TCP_CONG_BBR
CONFIG_NET_SCH_FQ
CONFIG_NET_SCH_CAKE
```

### 3. `moduled_kernel_configs.txt` - 编译为可加载模块

格式示例：
```
CONFIG_ZFS
CONFIG_WIREGUARD
```

---

## ⚠️ 其他

- **确保存在可启动内核**，具备救援能力后再使用
- **AI 编程警告**：请查阅代码后使用，防止不可预料的问题
- 仅供参考
