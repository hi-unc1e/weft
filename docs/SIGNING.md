# 固定 macOS 签名

本机和 CI 复用同一自签 code-signing 身份，不是 Apple Developer ID，不做公证。
固定证书及私钥、签名 identifier `me.weishu.Weft` 和 designated requirement，用于保持应用身份。
首次安装后由用户授权辅助功能，后续更新复用；实际授权延续由本机安装验收确认。
自签名仍可能触发 macOS 的未验证开发者提示。
自签证书没有 Apple Team ID，因此本地 Debug 也设置 `ENABLE_DEBUG_DYLIB=NO`，将代码保留在主二进制中，避免独立 debug dylib 被库验证拒绝；hardened runtime 和库验证保持开启。

本地入口：`bash scripts/build-local.sh`（依赖 XcodeGen）。
`python3 scripts/verify-signing.py <旧构建.app> <新构建.app>` 验证不同内容仍满足同一证书身份要求；签名证明不等于已获辅助功能授权，首次授权仍由用户确认。

## 本机产物与 secrets

由本地 bootstrap 管理 `~/.sign_keys_macos_app`（可用 `SIGNING_ROOT` 覆盖）：

| 文件 | 用途 |
| --- | --- |
| `signing.p12` | 加密 PKCS12，包含固定证书和私钥 |
| `p12-password` | PKCS12 密码 |
| `keychain-password` | 本机 bootstrap 专用 keychain 密码；CI 不复用 |
| `identity.sha1` | 40 位证书 SHA1，单行 |
| `certificate.pem` | 公共证书 |

这些文件不入库。维护者将下列三个 repository secrets 配入 `hi-unc1e/weft`：

| Secret | 内容 |
| --- | --- |
| `MACOS_SIGNING_P12` | `signing.p12` 密文的 base64 编码 |
| `MACOS_SIGNING_PASSWORD` | `p12-password` 内容 |
| `MACOS_SIGNING_IDENTITY` | `identity.sha1` 内容；公开指纹也存为 secret |

经授权配置时可用以下命令，避免将内容打印到终端或写进历史：

```bash
SIGNING_ROOT="${SIGNING_ROOT:-$HOME/.sign_keys_macos_app}"
base64 < "$SIGNING_ROOT/signing.p12" | gh secret set MACOS_SIGNING_P12 --repo hi-unc1e/weft
gh secret set MACOS_SIGNING_PASSWORD --repo hi-unc1e/weft < "$SIGNING_ROOT/p12-password"
gh secret set MACOS_SIGNING_IDENTITY --repo hi-unc1e/weft < "$SIGNING_ROOT/identity.sha1"
```

## 导入接口

`bash scripts/ci-import-signing.sh import` 优先读取完整的三个 secrets 环境变量；本机未设置时读取 `SIGNING_ROOT`。
GitHub Actions 中 secrets 缺失立即失败，不回退到文件或 ad-hoc 签名。
脚本不生成证书或私钥，不替换默认 keychain；保留搜索列表并临时追加专用 keychain，清理时删除该临时 keychain。

临时目录在 `RUNNER_TEMP`（本机回退 `TMPDIR`）下，由 `mktemp` 创建。
PKCS12 和密码文件权限为 `0600`；keychain 密码临时随机生成。
导入仅授权 `/usr/bin/codesign`，partition list 只作用于专用 keychain 中的私有签名密钥。
用系统 `/usr/bin/openssl pkcs12 -clcerts -nokeys` 从 PKCS12 提取公共证书，先校验其 SHA1。
自签证书仅导入 keychain 时可能被判定为不可信，导致按 SHA1 签名报 `specified item could not be found`。
本机 bootstrap 仅设置该证书的用户级 `codeSign` 信任。CI 的用户级信任可能等待 GUI 授权，因此只有 `GITHUB_ACTIONS=true` 且 `RUNNER_ENVIRONMENT=github-hosted` 的临时 runner 使用 `sudo -n security add-trusted-cert -d -r trustRoot -p codeSign` 非交互设置信任，任务结束移除；不影响维护者的系统信任，不扩大到 HTTPS 等其他用途。
导入和信任设置后立即删除临时 PKCS12 和密码文件。
自签身份通过真实签名探针及 `certificate leaf = H"SHA1"` requirement 验证，不依赖 `find-identity -v` 数量。
若上述限定信任仍不能签名，直接失败，不自动扩大信任。

成功导入输出 `WEFT_SIGNING_DIR`、`WEFT_SIGNING_KEYCHAIN`、`WEFT_SIGNING_IDENTITY` 到 `GITHUB_ENV`。
本机可 source 输出提示中的 `signing.env`，构建后执行：

```bash
bash scripts/ci-import-signing.sh cleanup
```

清理只接受临时根目录下带归属标记的 `weft-ci-signing.*` 目录。
`remove-trusted-cert` 在实际 hosted runner 中等待 GUI 授权并挂起，因此清理通过同一受支持的设置接口，将该证书的临时 `codeSign` 信任替换为显式 `deny`，并验证拒绝结果。只在临时 GitHub-hosted runner 执行；公开的 deny 记录随 VM 销毁，不在维护者本机执行。
随后删除私钥钥匙串、清理搜索列表并检查文件确已不存在，最后删除临时目录。命令和步骤均有超时；任一步验证失败仍报错，不能仅忽略异常。
脚本失败时自行清理，workflow 另用 `always()` 兜底；不删除固定签名目录。
本机模式使用本地 bootstrap 已建立的持久信任，不添加或移除证书信任。
不要在日常本机伪造 `GITHUB_ACTIONS=true`，此标志仅用于一次性 CI 用户。

## CI 与验收边界

PR 仅运行包测试，签名 job 仅允许本仓库 push 或手动触发。
push 范围为 `master`、`main`、`release/**`，token 仅有 `contents: read`。
测试任务在 macOS 15 上运行；签名打包任务在 macOS 26 上使用 Xcode 26.2，避开 macOS 15 上新图标编译服务的系统框架崩溃。版本依据 [runner 官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。
Release 构建 Apple Silicon 应用，关闭 debug dylib 和 DWARF 调试信息，扫描成品中的用户目录路径。
构建传入固定 SHA1 与专用 `--keychain`，验证签名、identifier `me.weishu.Weft`、证书叶节点 SHA1 和源码 revision 后上传 ZIP artifact，不发布 release。

CI 通过只证明构建与签名。首次授权及连续两次升级后辅助功能授权保持、与本机 designated requirement 一致，仍由本机验收。
