# 传输中心任务消失修复设计

## 目标

修复用户点击传输中的“暂停”操作后，任务从传输中心列表消失的问题；同时保证任务完成后仍能在默认列表中看到。

## 根因

`TransferCenterView` 对 `.hashing`、`.running` 等任务显示“暂停”按钮。点击后，`TransferManager.pause(_:)` 会把任务状态持久化为 `.paused`。

`TransferCenterViewModel` 默认使用 `statusFilter = .active`，而 `.active` 只匹配 `task.status.isExecuting`。`.paused` 不是执行中状态，因此任务仍保存在 `FileTransferTaskStore`，但被 `filteredTasks` 过滤掉，表现为“任务被删除”。任务完成后同样会因默认 `.active` 筛选而隐藏。

## 方案

保留方向和状态筛选能力，只把默认状态筛选从 `.active` 改为 `.all`。

- 默认进入传输中心时展示当前账号的所有状态任务。
- 点击“暂停”后，任务进入“已暂停”分组，仍留在列表中。
- 任务完成后，任务进入“已完成与失败”分组，仍留在列表中。
- 用户手动选择“进行中”时，仍只显示执行中的任务，不改变筛选语义。
- 不修改任务持久化、暂停、完成和清理逻辑，避免扩大修复范围。

## 测试

在 `TransferCenterViewModelTests` 增加回归测试：默认状态筛选为 `.all`，并验证暂停任务和完成任务都能出现在 `filteredTasks` 中；现有手动 `.active` 筛选测试继续验证暂停任务不会被归入“进行中”。

## 不在范围内

- 不改变任务状态机。
- 不改变清理已完成任务的行为。
- 不新增点击手势或任务详情页。
- 不修改上传、下载和网络协议。
