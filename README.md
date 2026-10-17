# 远程控制（iOS 控制端）

iPhone 远程控制安卓手机：iPhone → 上海云 TLS 网关 → SSH 反向隧道 → 安卓被控端（root）。

## 功能
- 实时屏幕（JPEG 轮询，约 3fps）
- 点击 / 长按 / 滑动 / 按键（返回、主页、多任务、电源、音量、唤醒）
- 文字输入（中文需安卓安装 ADBKeyboard，自动回退剪贴板）
- root 终端（等同 adb shell 最高权限）
- 设备信息、应用列表/启动、亮度、重启、日志

## 构建
GitHub Actions（macos-15）自动出未签名 IPA：`远程控制_V1.ipa`。

## 连接配置
- 网关：`https://110.42.185.227:18888`
- 令牌：见安卓模块 `/data/adb/rc-agent/agent.conf` 的 `TOKEN`
