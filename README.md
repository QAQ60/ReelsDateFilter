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
- **主页（任何人）一律不过滤**：从窗口根到当前可见控制器的解析路径只要经过主页控制器，整页所有列表原样返回（诊断里 `规则=profilePage`）。主页里的 Reels 分段/视频列表就是播放器的取数来源，砍条目必然导致播放器打不开被点的那条。设置面板里「个人主页」一行标注为「不过滤」且不可编辑。
- 其余页面正常过滤。**播放器与 Reels 标签页同名**，靠类名分不开，唯一可靠的差别是容器关系：播放器是「同类控制器」的子控制器（`parentViewController` 的类**完全相同**），标签页的父级是导航/标签容器（类不同）。命中时规则名 `reelsNested`。除此外只有三种情况会放过整份列表：① 解析链经过 Modal 且终点属于 Sundial 家族（播放器盖在最上层）；② 可见控制器本身是播放器类（`Viewer`/`Player`/`Playback`）；③ 查询适配器的 collectionView 还没上屏。规则名分别为 `modal` / `player` / `offscreen`，`#守卫` 一行会打印命中的那条，`#跳过` 记录最近一次被跳过的数据源。
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
