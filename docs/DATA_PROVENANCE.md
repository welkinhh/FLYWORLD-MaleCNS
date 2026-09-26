# FLYWORLD 数据来源与处理

## 成年连接组

- 数据集：MaleCNS v1.0，成年雄性 Drosophila central nervous system。
- 来源：MaleCNS/Janelia、Google Research 及合作机构的公开数据发布。
- 数据许可：CC BY 4.0；代码许可与数据许可分开处理。
- 运行时文件：`data/malecns/brain.npz`、`weights.npz`；两者由 `flybrain download` 获取，不提交到仓库。
- 哈希：brain.npz = `cc9bd1ecd00bd703a6fa648bc6ad145c93c7c1ee53debdcc9ce0d1f4305e6aca`；weights.npz = `c29919aa44069a271b1ee978abe05fa9bf6e45e4ba3e436e92b624ef1b5be40c`。
- 预处理：由 `alextitonis/fly.ai` 将公开 MaleCNS 连接与递质预测生成固定稀疏权重和群组元数据；本项目不重新标注神经 ID。
- 官方下载页确认 MaleCNS v1.0 提供全 CNS skeleton、脑区 ROI 与连接数据；本项目已将 166,700 个官方 SWC 转换为完整分支流，另保留 10 个带哈希语义标签的详细 JSON 子集。`build/morphology_coverage_report.json` 区分分支流、中心点和语义目录覆盖。官方入口：<https://male-cns.janelia.org/download/>。

## 成年形态

- 已从 MaleCNS v1.0 官方 skeletons-swc 路径获取 10 个展示神经元：10001、10010、10045、10056、10360、523769、10763、11288、25582、35051。
- 原始 SWC 是可删除的下载缓存；Godot 运行时使用已审计的 `assets/morphology/adult.json`。
- 每个 neuron/body ID、下载 URL、SHA-256、坐标单位、原始/展示节点数和降采样参数见 assets/morphology/manifest.json。
- 全脑观察底图 `assets/morphology/adult_full_brain.bin` 由本地 `data/malecns/brain.npz` 的 `ids` 与有限值 `positions` 生成：140,638/166,700 个有效神经元中心位置，8nm 坐标经运行时居中缩放；二进制仅用于批量点云显示，不替代神经骨架。后端以相同 body ID 回传稀疏放电。
- 连接边 LOD `assets/morphology/adult_connectome_edges.bin` 由同一 `weights.npz` 提取每个源神经元绝对权重最大的 4 条有效边，共 562,407 条；SHA-256=`64cbb706eca833f35fe26fe3928a02c8896e42b4ba3f555a83c105e6d34b109b`。它保留真实源/目标位置用于细节渲染，但不是完整突触边或完整分支替代品。
- 完整分支流可由官方 MaleCNS SWC 下载缓存和 `build_full_branch_lod.py` 重新生成，覆盖 166,700/166,700 个神经元、7,887,130 个拓扑保真显示节点，SHA-256=`0b619cd34810c08339dbdda97e3fb3b30bbf050669dd314738e1b049da1fc08c`；大于 GitHub 单文件限制，因此不作为运行时源文件提交。
- 运行时分支流 `assets/morphology/adult_runtime_branches.bin` 从完整流按固定每 14 个骨架抽样，覆盖 11,908 个真实骨架、563,722 个显示节点，SHA-256=`056c4e8fc4daeaa464a7798c826d03288d5bde750b3f61aac4906e18fa1c6e7c`。BrainView3D 使用该可验证 LOD 保持启动/切换流畅；完整成年分支流是可选重建产物，不随源码或发布包提供。

## 幼虫连接组与形态

- 阶段：Winding et al. 2023 一龄幼虫 L1 CNS（L1EM CATMAID）。
- 公开入口：`https://l1em.catmaid.virtualflybrain.org/`。
- 当前状态：公开 L1EM SWC 下载缓存可生成 `assets/morphology/larva_full_branches.bin`；`assets/morphology/larva.json` 保留 3 个语义标签子集。
- 所选 L1EM 子集的分支流 `assets/morphology/larva_full_branches.bin` 已由公开 CATMAID SWC 端点生成，覆盖 444/444 个 skeleton、21,312 个节点，SHA-256=`92fdde86e0c6fa0cf965607bb3900eeb9e02655fb34b8b8e7229b931e831ef39`；BrainView3D 在幼虫阶段加载该分支层。
- 处理要求：保留 CATMAID skeleton ID，标明 L1 阶段；不把幼虫模板插值成成年脑。

## 活动模型边界

- 成年活动：MaleCNS v1.0 brain.npz/weights.npz 的真实稀疏 LIF 计算，返回窗口内放电和读出。
- 幼虫形态：Winding 2023 L1EM 真实 SWC；活动使用 `brain_service/data/larva/l1em_connectome.npz` 中从 Winding Supplementary-Data-S1 提取的 444×444 真实连接子矩阵和明确标注的 LIF-lite 归一化适配。
- 连接资产哈希：l1em_connectome.npz = ea09b284c269f7c540d31d3097d9276cee4d97434fc9bed299a1675cdb96bd0d；原始 Supplementary-Data-S1.zip = 8c1f43809ed5d527ba61b154e377cc21da26383a75eda8aab85ce05607a72a4c。
- 连接源 ID 会映射到已加载的 parent-child 形态段，前端显示短暂传播脉冲；该动画不宣称测得轴突传导延迟。

## 源码交付范围

原始 Supplementary-Data-S1.zip 仅用于重新生成幼虫矩阵，源码不附带该归档。使用 tools/build_larva_model.py --source 指定外部原始包；上方保留其来源与哈希。运行使用 brain_service/data/larva/l1em_connectome.npz，不能按普通重复压缩包删除。
