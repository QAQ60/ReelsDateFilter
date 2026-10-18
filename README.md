# ReelsDateFilter

独立版 Instagram 插件：在**个人主页的短片标签页**按发布时间过滤，不依赖 RyukGram。

- 输入 `10`：只加载最近 10 天发布的短片
- 输入 `0.5`：只加载 12 小时内
- 输入 `-10`：只加载 10 天以前的
- 输入 `0` 或清除：关闭过滤
- 范围：**最短 1 分钟**（0.0007 天）～ **最长 1 年**（365 天），超出会提示
- 入口里可选择**作用范围**：首页 / Reels / 搜索·发现 / 个人主页，各自独立开关
- 输入时下方**实时换算**：`0.2` → 4 小时 48 分，`-0.3` → 7 小时 12 分（更早）
- 提示弹窗附单位说明：1 小时 = 0.0417，30 分钟 = 0.021

## 安装

**TrollFools / 自签注入（推荐）**

把 `ReelsDateFilter.dylib` 注入 Instagram 的 IPA 即可，无需改 plist。安装后打开 Instagram 的设置页，导航栏右上角会出现「时间过滤」按钮，不再有悬浮元素。

**越狱**

```bash
scp ReelsDateFilter.dylib root@device:/var/jb/Library/MobileSubstrate/DynamicLibraries/
scp ReelsDateFilter.plist root@device:/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

然后 `killall Instagram`。rootful 设备把 `/var/jb` 换成 `/`。

## 用法

1. 打开 Instagram 设置（个人主页右上角菜单 → 设置）
2. 点导航栏右上角「时间过滤」
3. 弹出提示，点「前往输入」
4. 输入天数，保存后列表立即收缩，按钮变成「10 天内」

设置存在 Instagram 的 `NSUserDefaults` 里，键名 `RDFDays`，重启 App 仍然有效。

## 实现

- 无 Logos、无 CydiaSubstrate 依赖，构造器里直接 `method_setImplementation`，方便注入非越狱 IPA
- `IGListAdapter setDataSource:` 被 hook，拿到当前页面的数据源对象
- 在数据源类上替换 `objectsForListAdapter:`，返回前按 `media.takenAtDate` 过滤
- 只处理类名含 `Sundial` / `Reel` / `Clip` 的数据源或对象，避免影响首页和「作品」标签
- 取不到发布时间的条目一律保留，不误杀
- 输入解析与判断逻辑在 `rg_date_filter.c`，纯 C，27 条断言（`core/tests.c` 于提案目录中）

日志前缀 `[RDF]`，可在「控制台」App 里确认是否挂上：

```
[RDF] hooked IGProfileReelsDataSource
[RDF] 21/32 (days=10)
```

## 已知限制

- **没有在真机上验证过。** 代码用 Instagram 449 的类名编写（`IGSundialGridVideoViewController`、`objectsForListAdapter:`、`media.takenAtDate`），编译通过，但 hook 是否命中取决于你设备上的 IG 版本。看日志里有没有 `[RDF] hooked` 即可判断。
- 如果某天 IG 改了数据源实现，过滤会静默失效，按钮仍在，列表不变。
- 分页由 IGListKit 自己管；当前页全被过滤时可能不再自动加载下一页，需要手动下拉。
- 设置页类名必须含 `Setting`，否则按钮不会出现；看日志里有没有 `settings class hooked`。

## 构建

仓库带 GitHub Actions，推 tag 或手动 `Run workflow` 即可产出 dylib（macos-14 + Theos）：

https://github.com/QAQ60/ReelsDateFilter/actions

本地构建需要 Theos：

```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
make
```

## 文件

| 文件 | 说明 |
| --- | --- |
| `Tweak.mm` | 手写 runtime hook、过滤、入口按钮、提示与输入弹窗 |
| `rg_date_filter.c/.h` | 输入解析与时间判断，纯 C |
| `ReelsDateFilter.plist` | 越狱加载过滤（仅 `com.burbn.instagram`） |
| `Makefile` | Theos，arm64 + arm64e |
| `.github/workflows/build.yml` | 云端构建 |
