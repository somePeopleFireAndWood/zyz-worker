# socket 活性判断细节（双分支 + 进程存活复核）

> 本文是 `skills/clean-tmp/SKILL.md` 第 2 步「分类」的配套参考资料，给出对疑似 unix socket / 含 socket 的运行时目录判断「持有进程是否还活着」的完整流程与退出码语义。

## 双分支：先找持有者 pid

```bash
# 分支 A（Linux 优先）：ss 对 unix socket 路径 → pid 的解析比 lsof 可靠。
if command -v ss >/dev/null 2>&1; then
  ss -lxp | grep -F "$sock"        # 从输出里解析出持有者 pid
# 分支 B（macOS / 无 ss 回退）：lsof。
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP "$sock"                 # 列出打开该 socket 的进程 pid（经典 lsof 视非选项参数为待查名，不用 --）
fi
```

- Linux 上优先 `ss -lxp`：它直接列出 listening unix socket 及其持有进程，对「socket 路径 → pid」的解析比 lsof 稳定。
- macOS 没有 `ss`，回退 `lsof -nP`（`-n` 不做 DNS 反解、`-P` 不做端口名反解，避免卡顿）。

## `kill -0` 复核：ESRCH 与 EPERM 必须分开

拿到候选 pid 后，用 POSIX 的 `kill -0` 复核该进程是否存活（替代 Linux-only 的 `/proc/$pid` 存在性判断，两端一致）：

```bash
if kill -0 "$pid" 2>/dev/null; then
  echo "ALIVE: keep"                       # 信号可达 → 活着
elif kill -0 "$pid" 2>&1 | grep -qi 'not permitted'; then
  echo "ALIVE (EPERM: 他人进程仍在): keep"  # 权限错误 = 进程存在 → 保留
else
  echo "GONE (ESRCH): 才可考虑 STALE"        # 唯有确认 no such process 才算真没了
fi
```

`kill -0` 的两种失败**语义完全不同**，绝不能混为一谈：

- **ESRCH**（no such process）→ 进程**确实没了** → 该 socket 才获得 STALE（僵尸）候选资格。
- **EPERM**（operation not permitted）→ 进程**还活着**，只是属于别的 uid、当前用户无权向它发信号 → 一律算 **ALIVE，保留**。

把「`kill -0` 非零退出」一律当作 gone 是经典错误：它会把他人的活进程误判为 STALE，进而删掉活 socket、切断活链路。

## 安全规则汇总

- 只有当「明确解析出持有者 pid **且** `kill -0` 确认 ESRCH」时，才可把该 socket 归为 STALE 候选。
- **持有者无法确定**（`ss`/`lsof` 都查不到、命令失败、输出无法解析）→ **默认 KEEP，归入「需要你拍板」（needs-your-call），绝不静默判 STALE 删除**。lsof 有时查不到活 socket 的持有者，冒进删除会杀掉活链路。自动模式下同样是保留 + 写进事后报告，绝不因查不到而删。

## 目录占用探测：`lsof +D`

```bash
# 判断某目录内是否仍有被打开的文件/进程占用（两端都有 lsof +D）：
lsof +D "$dir" 2>/dev/null
```

- `+D` 递归检查目录下所有条目是否被任何进程打开着。
- **macOS 上 `lsof +D` 可能明显偏慢**（它要为整棵子树 stat 每个打开文件），也可能需要额外权限；命令失败或超时时，**默认保留该目录**——「查不到占用」不等于「无占用」。
