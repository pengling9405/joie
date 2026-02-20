# joie

macOS 原生 SwiftUI 小工具：按住 `Fn` 开始语音识别，松开 `Fn` 停止并用 Apple TTS 朗读识别文本；朗读时再次按住 `Fn` 可立即打断并重新开始识别。

## 系统要求

- macOS 13+
- Swift 5+（Xcode 构建）

## 权限

首次运行需要在系统设置里授予：

- 麦克风
- 语音识别（Speech Recognition）
- 辅助功能（Accessibility，用于 `CGEventTap` 监听 `Fn`）

若未授予辅助功能权限，终端会打印提示。

## 运行

1. 用 Xcode 打开 `joie.xcodeproj`
2. 直接 Run（本工程已关闭 App Sandbox）
3. 运行后应用默认隐藏，按住 `Fn` 触发顶部胶囊

也可命令行构建（不签名）：

```bash
xcodebuild -project joie.xcodeproj -scheme joie -configuration Debug -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
```

构建后可直接从终端启动：

```bash
open .derivedData/Build/Products/Debug/joie.app
```

如需确认是否收到 `Fn` 事件，可开启调试日志并直接运行可执行文件：

```bash
JOIE_DEBUG_EVENTTAP=1 .derivedData/Build/Products/Debug/joie.app/Contents/MacOS/joie
```

## TODOs

### 已完成

- [x] Notch 交互状态接入：`idle / listening / speaking`
- [x] `Fn` 按住开始识别、松开结束识别并进入朗读
- [x] 朗读中再次按 `Fn` 可立即打断并重新进入识别
- [x] Notch 居中定位（基于硬件 Notch 中心）
- [x] 忽略本地构建产物目录 `.derivedData/`
- [x] 修复 `speaking` 被打断时偶发回落 `idle` 的竞态问题
- [x] ASR 流式展示：按住 `Fn` 时实时显示识别中的文本
- [x] Listening/Speaking UI 结构统一：顶部 `waveform + title`，下方文本
- [x] Listening/Speaking 尺寸、间距、边框与背景样式保持一致
- [x] 增加 `thinking` 状态：`listening -> thinking -> speaking`
- [x] ASR locale 自动跟随系统语言并回退到中文可用 locale
- [x] TTS 按文本语言自动选择语音（中文文本用中文 voice，英文文本用英文 voice）
- [x] Speaking 文本支持 Markdown 清洗（UI 展示与 TTS 播报均去除语法噪音）
- [x] Speaking 文本超过 10 行时固定高度并支持滚动查看，不再使用 `...` 截断
- [x] Speaking 播报结束后保留结果，右上提供复制/关闭按钮；关闭后回到 `idle`

### 待优化

- [ ] 进一步对齐参考仓库的动画质感（当前过渡仍偏生硬）
- [ ] 持续观察并优化顶部细缝的偶发场景（不同机型/缩放比）
- [ ] 增加最小化回归测试脚本（状态切换与事件流）
