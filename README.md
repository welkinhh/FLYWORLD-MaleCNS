# FLYWORLD

[简体中文] | [English](README.en.md)

FLYWORLD 是一个 Windows 桌面生态观察沙盒。果蝇生活在大树根下的 2.5D 后院中，会觅食、繁殖、发育、争夺资源并受到天敌影响。新一局从橙、蓝两组各 4 只成虫开始，种群上限为 30。

项目用于观察生态行为和学习神经数据可视化。主场景直接使用提供的迪士尼风格后院插画铺满画面，只在其上绘制果蝇、幼虫、天敌和糖块贴图；树木、草地、花朵、苔藓与两处烂香蕉都来自这张插画，不再叠加程序生成的树、围栏、植物或香蕉模型。生态规则是简化模型，不代表经过实验验证的完整果蝇生物学模拟。

## 下载游玩

1. 在 GitHub Releases 下载 Windows x64 发布包并完整解压。
2. 保持 FLYWORLD.exe 和 brain_service.exe 在同一目录，双击 FLYWORLD.exe。
3. 玩家不需要单独安装 Godot 或 Python；导出的 exe 内含 Godot 运行时，不会打开 Godot 编辑器。若同目录有 FLYWORLD.exe，也可双击 run_flyworld.cmd 启动。即使没有脑服务，花园生态仍可运行；连接大脑需要脑服务以及首次下载模型数据所需的网络连接。

脑模型数据由脑服务首次启动时下载到当前 Windows 用户的数据目录，不随发布包提交。连接失败时不会伪造电信号。

## 操作

- 点击果蝇查看个体状态和事件。
- 点击“连接大脑”连接当前个体；断开后脑图活动会清除。
- 点击“放糖”或“放天敌”，再点击花园中的位置进行放置。
- 点击“删除天敌”，再点击要移除的蜘蛛。
- 鼠标滚轮缩放；右键重置镜头；Esc 取消当前放置工具。
- 顶栏提供暂停、重新开始、x1/x2/x5/x10 倍速，以及温度、湿度和光照调节。

## 从源码运行

源码开发需要 Godot 4.7。将 Godot 可执行文件加入 PATH 后，在仓库根目录运行：

    ./run_flyworld.ps1

若 Godot 安装在自定义位置，可在 PowerShell 中指定：

    $env:FLYWORLD_GODOT = "C:/Godot/Godot.exe"
    ./run_flyworld.ps1

不安装 Python 也可以运行生态模拟。若要运行脑服务，请使用 Python 3.10 或更高版本，并在仓库根目录执行：

    python -m venv .venv
    ./.venv/Scripts/python.exe -m pip install --upgrade pip
    ./.venv/Scripts/python.exe -m pip install -r requirements.txt
    ./.venv/Scripts/flybrain.exe download --data data/malecns

Godot 会在启动时发现 .venv 和 brain_service/brain_service.py，并尝试启动本地脑服务。也可以手动运行：

    ./.venv/Scripts/python.exe brain_service/brain_service.py --model malecns --data data/malecns --dt 0.001 --port 8765

## 构建 Windows 发布包

安装 Godot 4.7 Windows export templates，并在仓库根目录执行：

    ./.venv/Scripts/python.exe -m pip install -r tools/requirements.txt
    ./tools/build_windows.ps1 -GodotPath "C:/Godot/Godot.exe"

输出为 build/FLYWORLD-windows.zip。脚本把游戏、脑服务、幼虫运行数据和许可文件一起打包。压缩包只作为发布产物保存在 build/，不属于源码；上传 GitHub 时放在 Releases。

## 脑图与模型说明

- 成年果蝇后端使用 MaleCNS v1.0 公开连接组数据和数值神经网络模型。
- 幼虫后端使用 Winding 2023 L1EM 连接矩阵上的 LIF-lite 适配模型。
- 活动帧映射到数据集的神经元 ID；脑图高亮显示对应结构和拓扑路径。
- 这些信号是连接组驱动的计算模拟，不是活体果蝇的实时脑电记录。形态上的脉冲效果也不是实测电压或轴突传导延迟。

## 代码结构

| 路径 | 作用 |
| --- | --- |
| Main.tscn | Godot 主场景 |
| scripts/main.gd | 生态状态、行为、生命周期、存档与界面协调 |
| scripts/garden_view_3d.gd | 后院插画、果蝇和可放置对象的贴图渲染 |
| scripts/brain_view_3d.gd | 神经元形态、连接和活动可视化 |
| scripts/neural_adapter.gd | Godot 与本地脑服务的协议适配 |
| brain_service/ | Python 神经服务及 WebSocket 协议 |
| assets/morphology/ | 运行所需的形态目录和压缩数据 |
| assets/environment/ | 铺满主画面的后院场景插画 |
| assets/sprites/ | 果蝇、幼虫、蛹、蜘蛛和糖块的角色素材表 |
| brain_service/data/larva/ | 必需的幼虫模型矩阵与来源元数据 |
| tests/ | 行为、交互、神经数据和性能检查 |
| tools/ | 数据重建和发布打包工具 |
| docs/ | 数据来源、神经输入和通信协议 |
| data/ | 被 Git 忽略的本机下载缓存 |
| third_party/flybrain/ | 上游 flybrain 运行库源码 |

运行确定性回归检查：

    godot --headless --path . --script res://tests/observation_regression.gd -- --flyworld-test
    godot --headless --path . --script res://tests/behavior_regression.gd -- --flyworld-test

## 许可与数据来源

项目代码采用 MIT License。第三方 flybrain 运行库保留上游 MIT License。MaleCNS、L1EM 及其他数据的来源、许可、哈希和转换范围见 [DATA_PROVENANCE.md](docs/DATA_PROVENANCE.md) 与 [SOURCES.lock.json](SOURCES.lock.json)。项目代码许可不代表第三方科学数据也采用 MIT 许可。

源码不附带参考图片、论文原始压缩包或构建缓存。第三方包保留上游文件和许可，数据重建步骤见 [tools/README.md](tools/README.md)，检查说明见 [tests/README.md](tests/README.md)。
