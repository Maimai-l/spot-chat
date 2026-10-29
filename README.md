# Spot Chat

macOS 原生浮动 AI 小窗：全局快捷键唤起，后端接自己的 OpenAI 兼容 API。

## 安装

1. 在 GitHub Actions 最近一次成功的 CI 运行里下载 `SpotChat-app`，解压得到 `SpotChat.app`，拖进「应用程序」。
2. 应用没有经过公证，第一次打开前在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/SpotChat.app
   ```

3. 打开后菜单栏出现图标，按 Option+Space 唤起小窗。

## 本地构建

需要 Xcode 16 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
open SpotChat.xcodeproj
```

核心逻辑的测试不依赖 Xcode 工程：

```bash
swift test --package-path Packages/SpotCore
```

## 使用的库

| 用途 | 库 |
| --- | --- |
| 全局快捷键与快捷键录制 | [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) |
| 生成 Xcode 工程 | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
