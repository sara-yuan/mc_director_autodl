# mc_director_autodl

MiniMax H3 导演台的 AutoDL Art 发布源。

## 发布模型（最终是 1 个入口）

AutoDL Art 上的最终形态是 **1 个应用/镜像入口**，但底层由三部分组成：

- `GitHub`：只放代码、部署脚本和模型清单（本仓库）。GitHub 单文件上限 100MB，**不能**放 135GB 模型。
- `AutoDL 公共模型库`：放全部模型权重；实例里通过 `/.autodl/...` 软链接到 `ComfyUI/models/...`。
- `AutoDL 保存镜像`：放 ComfyUI 应用、依赖、启动脚本；审核要求 `/root` 下存在对应 Git 仓库。

所以“一个镜像”不是“一个 Git 大文件”，而是 AutoDL Art 上用户最终只会加载一个入口。

## 版本

- ComfyUI：`0.30.0`
- 仙宫源：`/root/mcminimaxh3`
- 应用逻辑大小：约 `118 GB`（`du -Lsh`）
- 文件表观大小：约 `135.09 GB`（含稀疏文件展开）
- 模型清单：`manifest/models_manifest.json`

## 目录

- `deploy/setup.sh`：安装 torch / ComfyUI 依赖 / 自定义节点依赖 / SageAttention
- `deploy/start_comfy.sh`：启动 ComfyUI
- `deploy/stop_comfy.sh`：停止 ComfyUI
- `deploy/watchdog.sh`：看门狗
- `deploy/preflight.sh`：部署前检查
- `manifest/models_manifest.json`：仙宫完整模型清单（80 个模型文件）

## 后续

1. 把全部模型上传到 AutoDL Art 公共模型库。
2. 按 AutoDL 返回的 `/.autodl/<uuid>` 生成 `deploy/link_models.sh`。
3. 保存一个 AutoDL 镜像，`/root/mc_director_autodl` 指向本仓库。
4. 在 AutoDL Art 发布 1 个镜像/应用入口，选择该镜像并填启动命令。
