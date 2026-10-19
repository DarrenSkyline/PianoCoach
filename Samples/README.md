# 测试曲谱

`导入测试曲.musicxml` / `导入测试曲.mxl` 是手写的测试文件（不是任何出版物），用来验证 MusicXML 导入：

- 弱起小节、3/4 拍、F 大调（B♭）、速度 76
- 左手和弦、右手跨小节连音线
- 反复记号 + 一房 / 二房（展开后演奏顺序：弱起, 1, 2, 3(一房), 1, 2, 4(二房), 5）

单元测试 `PianoCoachTests/MusicXMLParserTests.swift` 里的 `sampleFile` 用 music21 的解析结果作为期望值。

## 在模拟器里手动导入

1. 运行 App 到模拟器
2. 把这个文件从 Finder 拖到模拟器窗口上 → 会保存到"文件"App
3. App 里点曲目菜单 → "导入 MusicXML…" → 选择文件
