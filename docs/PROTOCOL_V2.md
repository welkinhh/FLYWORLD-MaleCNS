# FLYWORLD 本机 WebSocket 协议 v2

协议仍只监听 `127.0.0.1:8765`，每个 RFC6455 文本帧包含一个 JSON 对象。

v2 继承 v1 的 `world_uuid`、`epoch`、`selection_session`、永久 `fly_id`、阶段和序列校验，并额外区分三类时间：

- `input_world_time_s`：这组感官输入对应的生态世界时间；
- `model_start_s` / `model_end_s`：模型自己的积分窗口；`actual_model_dt_s`：实际积分步长（必须等于 `model_end_s - model_start_s`）；
- `compute_latency_ms`：从服务端开始计算到形成结果的墙钟延迟。

请求还携带 `requested_model_dt_s`（交互目标 1ms）和 `model_window_s`。当前成年 MaleCNS 交互适配器默认以 1ms 积分，幼虫 L1EM LIF-lite 保持 20ms 校准步长；两者都由 `actual_model_dt_s` 如实返回，不能把目标步长冒充已完成的验证。

成年感觉驱动经过 1.8ms 的输入延迟队列后才注入连接组，响应仍按实际模型窗口记录源 ID 放电；这不是完整突触延迟重建，但不会再把输入在同一积分步直接写入网络。

`normalized_inputs` 分开记录 `food_odor`（远距离气味）、`food_contact_taste`（接触味觉）、`threat_left`、`threat_right` 和 `threat_approach`；温湿度等缺乏可靠神经映射的状态仍只影响生态行为，不强行伪造成神经刺激。

`activity` 的 `spike_events` 是带 `neuron_id` 和 `model_time_s` 的稀疏来源 ID 事件，`neuron_rates_hz` 只从该模型窗口内的实际计数计算。`morphology_coverage` 返回预期清单、实际加载清单和缺失报告；不完整时 `complete=false`。

暂停、个体/阶段切换或世界切换都应使旧 `epoch`/`selection_session` 结果失效。前端可以保留真实活动的短余辉，但余辉不是新的放电，也不能用它推断枝条上的传播。
