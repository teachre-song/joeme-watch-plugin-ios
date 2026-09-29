# build-ios/dcuni-inc/

编译 `nativeplugins/joeme-watch/ios/JoemeWatchModule.m` 时要用 `#import "DCUniModule.h"`。

## 本目录现在是空的，需要手动放文件

从 **uni-app iOS 离线打包 SDK** 里把 `inc/` 目录下的头文件拷进来，至少要有 `DCUniModule.h`（它还会 include 别的头，整个 `inc/` 一起拷最省事）。

- 下载页：<https://nativesupport.dcloud.net.cn/AppDocs/download/ios.html>
- 正式版（2026-09-18，HBuilderX 5.26.2026091802）：百度网盘提取码 `a6sb`
- **版本要和 HBuilderX 对得上**（本项目用它做云打包）
- 解压后头文件在 `SDK/inc/`（有的版本是 `HBuilder-Hello/inc/`）

放好之后：

```
build-ios/dcuni-inc/
├── DCUniModule.h
├── DCUniComponent.h
├── DCUniDefine.h
├── ...（inc 下的其他头文件）
└── README.md
```

## ⚠ 不要自己写 stub 版 DCUniModule.h

`UNI_EXPORT_METHOD` 的展开负责把方法注册给运行时，展开规则未公开，`DCUniModule` 基类还带 `uniInstance` / `uniExecuteQueue` / `uniExecuteThread` 等 ivar。写假的会静默失效或 ivar 布局错位。用官方的。

## 版权提醒

这批头文件是 DCloud 的 SDK 内容，是否提交进公共仓库请确认符合授权范围；若不宜公开，可把本目录排除出 git（加入 .gitignore）并在 CI 里用 secret/下载步骤铺进，或改用「租 Mac 手动跑脚本」。
