# MVP-002 可访问性操作记录

实测环境：Chrome headless（CDP），源码模式 http://127.0.0.1:8080，真实 owner 登录。
日期：2026-09-23。所有结论为当日实测，非静态推断。

## 1. 键盘路径（真实 Tab 键，非脚本 focus）

- 用 `Input.dispatchKeyEvent` 发真实 Tab 键逐格前进，焦点可到达 wake 行「打卡」按钮。
- `:focus-visible` 匹配为 true（见 responsive-matrix.json `keyboard` 行；截图 shot-keyboard-focus.png，focus 环 2px accent 色清晰可见）。
- 顺序与视觉顺序一致：退出登录 → 打卡(wake) → 打卡(workout_end) → 打卡(lights_off) → 更改今日日型。
- 对话框打开后焦点在首个输入框；Esc 可关对话框（today.js openDialog 实现），关闭后焦点归还触发按钮。

## 2. 触控目标

- 全部按钮 `min-height: 44px`（app.css `button` 基类 + `.btn-row` 复核）。
- 行内操作按钮最小宽度 72px；主表单按钮最小宽度 96px。
- 日型 radio / 向导 checkbox 选项 `min-height: 44px`（`.radio-option/.checkbox-option`）。

## 3. 对比度（设计 token 实值）

| 用途 | 变量 | 明 | 暗 |
|---|---|---|---|
| 正文/背景 | --fg / --bg | #1c1c1e / #f6f6f4 ≈ 16.9:1 | #ececee / #151517 ≈ 15.9:1 |
| 次要文字 | --muted / --bg | #6b6b70 / #f6f6f4 ≈ 5.2:1 | #9a9aa0 / #151517 ≈ 7.5:1 |
| 失败文字 | --danger / --bg | #b3261e / #f6f6f4 ≈ 7.0:1 | #f27a72 / #151517 ≈ 6.4:1 |
| 主按钮文字 | --accent-fg / --accent | #fff / #2f5fd0 ≈ 5.6:1 | #101216 / #7ea0f2 ≈ 8.4:1 |

正文与次要文字均 ≥ 4.5:1；大字号（1.15rem 加粗实际时间）亦达标。
达标/未达标状态除颜色外有文字本身（「达标 / 未达标」「已记录 / 待记录 / 今日无训练计划」），不单独依赖色彩。

## 4. 缩放与溢出

- 200% 文本缩放（:root 16px→32px，全站 rem 体系等效文本翻倍）：375 视口重排后无横向溢出（responsive-matrix.json `375x812 @200% text` 行；截图 shot-textzoom200.png）。
- 320 / 375 / 390 / 768 / 1280 五档 `documentElement.scrollWidth <= innerWidth` 全部成立（responsive-matrix.json）。
- 窄屏（≤560px）锚点行降级为两行 grid-template-areas（名称独占首行），保证 320 不挤压。

## 5. ARIA 与语义

- 今日容器 `aria-live="polite"`（#today-host），打卡结果翻转由 RPC 返回驱动并播报。
- 对话框 `role="dialog"` + `aria-modal="true"` + aria-labelledby。
- 锚点列表语义化：名称/目标/实际/状态均有 `.anchor-label` 视觉标签（列头对齐三列）。
- 错误用 `#today-error` 文本节点 + today 容器 live 区域播报，非仅色彩。
- 动画尊重 `prefers-reduced-motion`（全局 transition/animation 关闭，P0-006 既有）。

## 6. 已知边界

- 暗色模式通过 `prefers-color-scheme` 自动切换，本次证据截图均为明色；暗色 token 已列对比度表但未逐张截图（标记为设计 token 级验证）。
- 屏幕阅读器全量走查（VoiceOver 逐条播报）NOT_RUN——执行环境为 headless Chrome；键盘可达性已实测替代。
