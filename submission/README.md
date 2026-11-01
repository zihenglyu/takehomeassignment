# Submission Pack — BA3073 Take-home Assignment

生成时间：2026-11-01

这个目录用来存放**提交物**，不包含任何密钥。

## 提交清单

| # | 要求 | 状态 | 位置 |
| --- | --- | --- | --- |
| 1 | 作业报告（≤20 页，PDF） | ⬜ 待生成（需要 3 张截图） | `submission/assignment-report.pdf` |
| 2 | GitHub 仓库链接 | ⬜ 待推送 | 见下方「推送仓库」 |
| 3 | `local-ui-check.txt` | ✅ 已完成 | `submission/evidence/local-ui-check.txt` |
| 4 | `ecs-docker-check.txt` | ✅ 已完成 | `submission/evidence/ecs-docker-check.txt` |

附加证据（建议一并放进报告附录，不必单独提交）：

- `submission/evidence/https-domain-check.txt` — Task 3 的 HTTPS / 访问控制检查记录

## 还需要你做的三件事

### 1. 截三张图

| 文件命名 | 截图内容 | 要求 |
| --- | --- | --- |
| `submission/screenshots/01-local.png` | 本地 `http://127.0.0.1:14242/ui/` | 浏览器**地址栏必须可见** |
| `submission/screenshots/02-ecs.png` | ECS `http://8.138.30.102:14242/ui/` | 地址栏必须可见 |
| `submission/screenshots/03-https.png` | `https://takehomeassignment.michaellyu.fyi/ui/` | 地址栏必须可见 |

截图放到 `submission/screenshots/` 目录，命名如上（后缀 jpg 也可以，修改下方命令即可）。

> 注意：Task 3 目前**已按你的要求去掉 Basic Auth**，所以第三张图是直接打开页面的状态。
> 如果助教按 rubric 检查「access-control check」，这一项可能被扣分。
> 恢复方式见本文件最后的「恢复 Basic Auth」。

### 2. 生成报告

1. 打开已部署的应用：<https://takehomeassignment.michaellyu.fyi/ui/>（或 ECS 的 14242 端口）
2. 新建任务，类型选 **essay / report**
3. 把 `submission/report-request.md` 里的全部内容粘贴进去
4. 生成完成后下载 `main.html` 与 `main.pdf`
5. 用浏览器打开 `main.html`，把它放进 `submission/`，再手工把三张截图替换进文中的
   `Figure 1/2/3 (screenshot placeholder)` 占位框：
   ```html
   <img src="screenshots/01-local.png" alt="Local web interface" style="max-width:100%">
   ```
6. 用浏览器「打印 → 另存为 PDF」（A4、默认边距）导出最终版，命名：
   `submission/assignment-report.pdf`

### 3. 推送仓库

本地仓库已经初始化完成（分支 `main`，已有首个提交 `c9b8179`），只差远端：

```bash
# 先在 GitHub 上新建一个空仓库（不要勾选 README/.gitignore）
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

仓库里已经排除了 `.env.ecs`、`data/`、`workspace/`、`.venv/`、`node_modules/` 等敏感/体积目录，
但**推送前请再确认一次**：

```bash
git ls-files | grep -E '(^|/)\.env|model-secrets|\.venv/|(^|/)data/|(^|/)workspace/'
# 期望：无输出
```

## 部署事实（写报告时可直接引用）

| 项目 | 值 |
| --- | --- |
| 本地运行时 | WSL2 / Ubuntu 26.04，Docker Engine 29.9.2 |
| 本地地址 | `http://127.0.0.1:14242/ui/` |
| ECS 系统 | Debian GNU/Linux 12 (bookworm)，Docker 29.2.1 |
| ECS 公网 IP | `8.138.30.102` |
| 镜像仓库 | `crpi-otou15rf69k33qkj.cn-guangzhou.personal.cr.aliyuncs.com/michaellui/takehome:latest` |
| 容器端口映射 | `0.0.0.0:14242->14242/tcp` |
| 域名 | `takehomeassignment.michaellyu.fyi`（A 记录 → 8.138.30.102） |
| 反向代理 | Nginx 1.22.1，`/etc/nginx/sites-available/ai-agent` → `127.0.0.1:14242` |
| 证书 | Let's Encrypt，CN=takehomeassignment.michaellyu.fyi，有效期至 2027-01-30 |
| 健康检查 | `curl https://takehomeassignment.michaellyu.fyi/health` → `{"status":"ok"}` |

## 已知问题（可以写进报告的"改进"章节，属于真实云环境约束）

1. **域名未做 ICP 备案** → 阿里云在 80 端口返回
   `403 Non-compliance ICP Filing`，`http://` 无法跳转 HTTPS；443 正常。
   部署在境外区域的 ECS 可避免。
2. **ECS 无可用 IPv6 路由**，但 DNS 同时返回 A/AAAA，导致 Certbot 优先连 IPv6 超时。
   通过 `/etc/gai.conf` 增加 `precedence ::ffff:0:0/96 100` 强制 IPv4 解决。
3. **ACR 拒绝 buildx 默认生成的 attestation manifest**
   （`unknown manifest class for application/vnd.oci.empty.v1+json`），
   需要 `--provenance=false --sbom=false` 构建。
4. **单实例部署**，无高可用；SQLite 单文件，备份靠卷快照。

## 恢复 Basic Auth（可选）

```bash
ssh root@8.138.30.102 'cd /etc/nginx/sites-available && cp $(ls -t ai-agent.bak.* | head -1) ai-agent && nginx -t && systemctl reload nginx'
```
