# FLYWORLD — Windows

完整解压发布包，保持 FLYWORLD.exe 与 brain_service.exe 在同一文件夹，双击
FLYWORLD.exe（也可双击 run_flyworld.cmd）。游戏 exe 已包含 Godot 运行时，不会
打开 Godot 编辑器。玩家无需单独安装 Godot、Python 或其他开发工具。

首次启动脑服务会下载成年模型数据并初始化计算，耗时取决于网络和电脑性能。
数据保存在当前用户目录，后续启动复用。花园可以在脑服务未连接时运行。

- 点击果蝇：查看个体状态与事件。
- 连接大脑 / 断开大脑：控制所选个体的神经模型连接。
- 放糖 / 放天敌：选择工具后点击花园位置。
- 删除天敌：选择工具后点击蜘蛛。
- Esc：取消工具；滚轮：缩放；右键：镜头复位。
- 顶栏：暂停、重新开始、倍速、温度、湿度和光照。

重新开始会重置世界时间和果蝇编号。神经信号来自连接组驱动的计算模型，
模型说明与来源见 [DATA_PROVENANCE.md](DATA_PROVENANCE.md)。

如果无法连接大脑，先检查 brain_service.exe 是否与游戏在同一目录，以及首次
运行能否访问模型下载地址。首次下载未完成时可继续观察花园。

For English-speaking players: extract both executables into the same folder and
launch FLYWORLD.exe. No Godot editor or Python installation is required. Neural
model data is downloaded on the first service startup and cached per user.
