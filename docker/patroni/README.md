# docker/patroni

库自动选主的镜像与配置:`Dockerfile`(supabase postgres + Patroni)、`Dockerfile.haproxy`(库入口 / 盯守 / 证书落地)、`service/`(平台标准部署用的 compose,清单见仓库根 `.deploy.patroni.yaml`)、`tls/gen-certs.sh`(私有 CA 与节点证书)、`guard.py`(两机房同时坏接管后的盯守)、`clients/` + `Dockerfile.clients`(演练用持续写入客户端)。
方案与演练结果见 one 仓 `docs/db-switchover-smooth-progress.md`;应急操作走 one 的应急系统能力 `supabase.patroni_*`。

## 本地提交检查

在子仓根运行 `scripts/install-hooks.sh`，只安装本仓提交前钩子，不动父仓或分支保护钩子；重复运行安全。若检测到自定义 `core.hooksPath`，为避免覆盖共享目录而拒绝安装。在 one 中保留共享钩子的前端、分支及部署配置检查，独立克隆直接执行后端门禁。父仓重新安装共享钩子后，仍会经约定入口调用 `scripts/oosp-lint.sh --staged`。

检查依赖 Python 3.9+、ShellCheck 和支持 `!override` 的 Docker Compose 2.24.4+（或 5.x）。只执行 `compose config`，无需启动 Docker 引擎，不构建镜像、不启动容器。Python 依次使用显式 `PYTHON`、本仓 `.venv/bin/python`、父仓 `.venv/bin/python`、系统 `python3`；选中的解释器缺依赖即阻断，不自动安装或跳过检查。独立克隆的安装示例：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/requirements-hooks.txt
brew install shellcheck docker-compose
scripts/install-hooks.sh
```

Docker Compose 插件须能由 `docker compose version` 调用；Docker Desktop 已包含。`.venv/` 是本地工具环境，不提交。需要复查时运行：

```sh
scripts/oosp-lint.sh --staged
LINT_SCOPE=full scripts/oosp-lint.sh
```

暂存模式遇到 `docker/patroni/`、`scripts/`、`.deploy.patroni.yaml` 的新增、修改、删除或重命名，就检查整片后端；其它提交跳过。检查语法、Ruff 的 F/E9 规则（含未定义变量）、ShellCheck 全部级别、YAML 语法、生产 Compose 及沙箱叠加配置，并运行全部本仓离线测试。Compose 只用 `scripts/tests/compose.env` 的假数据，清空宿主环境，不读取生产凭证。全量模式检查主线工作区的同一范围，包含尚未跟踪且未被忽略的文件；不扫描上游 Supabase 代码。

测试在主线工作区原地运行；提交检查只扫描已跟踪文件并加载已纳入提交的测试,不把其它会话未跟踪的半成品纳入本次提交或测试。已跟踪的被测范围若与暂存版本不一致,先阻断并列出路径,避免工作区修复掩盖暂存错误。全量检查仍包含全部未跟踪文件。生成目录和已有 `__pycache__` 不参与。请勿跳过钩子。

OOSP 规则覆盖 Python 内部时钟/随机调用、空异常处理、约定缩写、数值单位，源文件图形符号及 SQL 迁移幂等。`scripts/oosp-baseline.json` 逐行登记 24 处存量偏离（含两处 ShellCheck 提示），按路径、规则、内容及次数精确匹配；新增或复制违规不能借存量登记放行。它不是整文件豁免；修掉存量时同步删除对应登记，不扩充登记来放过新增问题。本轮不改变运行代码。

有意偏离：本片是容器脚本与命令行工具，不提供业务 HTTP API，公开 API 覆盖率不适用；测试类继承标准库测试框架。运行外壳必需的文件、环境和进程操作不迁成业务层。依平台部署规范的明确约定，持续集成在本地执行，不新增 GitHub Actions；因此不声称已完整自动执行 OOSP §14 的全部架构语义与远端持续集成要求。
