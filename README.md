# ReelsDateFilter

独立版 Instagram 插件：在**个人主页的短片标签页**按发布时间过滤，不依赖 RyukGram。

- 输入 `10`：只加载最近 10 天发布的短片
- 输入 `0.5`：只加载 12 小时内
- 输入 `-10`：只加载 10 天以前的
- 输入 `0` 或清除：关闭过滤
- 范围：**最短 1 分钟**（0.0007 天）～ **最长 1 年**（365 天），超出会提示
- 入口里每个页面有独立开关和独立时长：首页 / Reels / 搜索·发现 / 个人主页，点某一行单独设置
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
- 播放器在屏时不过滤，三条结构信号兜底：① 主页里的 Reels 列表不过滤——主页自带的 Reels 分段/预览条由共享的 Reels 数据源构建，适配器属于主页控制器（或其子控制器），点开视频时 Instagram 把这份已建好的列表直接交给播放器，砍掉条目必然导致播放器找不到被点的视频而回退第一条；② 控制器解析链经过 Modal 且终点属于 Sundial 家族（播放器上场；标签页自己永不被 Modal 呈现）；③ 查询适配器的 collectionView 还没挂到任何 window——播放器在被 present 之前就用自己的 IGListAdapter 查询共享数据源组建播放列表，此刻任何基于「当前屏幕」的守卫都看不到它，而标签页的 collectionView 在用户看到它时一定在屏。再配合播放器生命周期跟踪（viewDidAppear 记录、被 Modal 盖住或移出窗口即失效）。诊断行 `#守卫` 会打印命中的规则名（`profileReels` / `player` / `modal` / `adapterPlayer` / `offscreen` / `viewer` / `none`）
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
- **主页里的 Reels 列表不过滤**（主页「作品」网格仍然按「个人主页」时长过滤）。那份列表是播放器的入口，过滤它就会重现「跳回同一条」；两者不可兼得，除非能改写播放器取列表的实现。
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
