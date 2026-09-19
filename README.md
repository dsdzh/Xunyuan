# 寻源 (Xunyuan)

基于 Flutter 的安卓阅读应用，支持导入 [Legado（阅读3.0）](https://github.com/gedoor/legado) 书源 JSON。
架构参考 [DandanLLab/mr](https://github.com/DandanLLab/mr)，代码为独立实现。

## 功能（v0.1）

- 书源管理：从剪贴板 / 文件 / URL 导入 Legado 书源 JSON，启用/禁用、删除、导出
- 规则引擎（纯 Dart 子集）：CSS/JSoup 风格选择器（`class.` `id.` `tag.` `text.` `@css:`）、
  属性抽取（`@text` `@html` `@href` `@src` 等）、JSONPath 子集（`$.a.b[*]` `$..key`）、
  正则替换（`##re##替换` `###re`）、规则组合（`&&`）与回退（`;;`）
- 搜索：多书源并发搜索、单源过滤
- 发现：书源 exploreUrl 分类
- 阅读：目录解析（含 nextTocUrl 翻页）、正文抓取（nextContentUrl 自动拼接）、
  章节缓存、GBK/UTF-8 自动解码、Cookie 管理
- 书架：多主题（5 套配色）、字号 / 行距、滚动 / 翻页两种模式、进度记忆

## 已知限制

- 不支持 `@js:` / `@xpath:` / 模板规则 / 需要 JS 加密的书源（后续版本计划）
- 不含漫画 / 音频 / 视频播放器（规划中）

## 开发

```bash
flutter pub get
flutter run            # 连接 Android 设备
flutter build apk --debug
flutter test           # 规则引擎单测
```

依赖国内镜像：Gradle 分发使用腾讯镜像，Maven 使用阿里云镜像（见 `android/` 下配置）。
