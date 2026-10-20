# Minis × MT-Agent 环境嫁接

把 MT-Agent 的原生工具链环境接进 OpenMinis(Minis),产出 TrollStore 可装的 `.tipa`。

---

## 1. 先把"环境"这个词拆开

Minis **有**环境 —— 它内置 iSH,一个跑在用户态里的 x86 Linux 内核,里面是 Alpine。
MT-Agent 的"有环境"是另一回事。拆开 MT-Agent 的 `1.0.5-Lite.tipa` 之后,里面是:

```
Payload/CodexApp.app/
├── Helpers/
│   ├── ca-filetool       167 KB   arm64 多重调用宿主(按 argv[0] 分发)
│   ├── bash.real         792 KB   arm64 真 GNU bash
│   ├── codex-sign        3.4 MB   arm64 签名器(含 CoreTrust bypass)
│   ├── bash sh ls cat …          30 个符号链接 → ca-filetool
│   ├── TheosCompat/              cp mv tar
│   └── TheosCoreCompat/          mkdir rm touch
├── entitlements.plist            platform-application 等 10 项
└── Info.plist                    CARuntimeManifestURL → 运行时清单
```

`ca-filetool` 里能捞出 `CATheosHelperAssembleDeb` / `CATheosHelperVerifyDebArchive` /
`CATheosHelperWriteArMember` —— **它能在设备上直接打 .deb 包**。

再看 `runtime-manifest.json`(schema 3),真正的环境体量在这里,全部走 OTA:

| key | 内容 | 下载 | 解包 |
|---|---|---|---|
| `core_tools` | git 2.39.1、ripgrep 15.2、curl 8.22、jq 1.8.2、file/diff/patch/zip | 9.9 MB | 24 MB |
| `node` | Node 18.20.4 + npm 10.7 + pnpm/yarn + iOS arm64 node-gyp | 20 MB | 84 MB |
| `python` | CPython 3.13.14(ssl/sqlite3/hashlib) | 8.9 MB | 33 MB |
| `ollvm` | Obfuscator-LLVM clang 16(间接跳转/字符串加密/控制流平坦化) | 27 MB | 92 MB |
| `reverse_tools` | radare2 6.2.4、mt-macho、mt-rev、mt-inject-dylib | 17 MB | 49 MB |
| `theos` | 完整 Theos,内嵌 iPhoneOS16.5.sdk,出 rootful/rootless/roothide deb | 224 MB | 980 MB |
| `codex` | MT-Agent 自己的 agent 宿主 | 99 MB | — |

所以"环境"= **三件事**,缺一个都不成立:

1. **原生执行宿主** —— `posix_spawn` 拉起 arm64 真二进制。iSH 是翻译执行,永远跑不了 clang/node/radare2。
2. **平台权限** —— `platform-application` + `no-sandbox` + `no-container`。没有它内核直接拒 `exec`,`process-exec` 检查返回 EPERM。
3. **运行时安装器** —— 按清单下载、验 SHA-256、解包、重签名、probe 校验。

Minis 三样都没有。它有的是 iSH 那套模拟环境。Npc 的判断是对的。

---

## 2. 接在哪儿

`src/ios/Agent/ISH/ISHExecutionCoordinator.swift`(57 KB)是**唯一收口**:
挂载、fs_context 路由、抢占、环形缓冲、超时保底输出全在里面。所有 shell 工具调用
(`AIChatViewModel+ISHCommand.swift` → 这里)都从这一个方法过。

所以嫁接点只有一个,加一个前置分支:

```swift
if await NativeShellBackend.shared.isAvailable {
    do {
        return try await NativeShellBackend.shared.execute(…).ishResult
    } catch {
        logger.warning("native backend failed, falling back to iSH: …")
        // 落到下面上游逻辑,iSH 行为原样保留
    }
}
```

普通签名装的 Minis:没资格 → 检查一次就落回 iSH,行为和上游一模一样。
TrollStore 装的:走原生,`bash -lc` 直接跑真二进制。

---

## 3. 已交付文件

```
minis-env/
├── src/ios/RuntimeHost/            落到 OpenMinis 的 src/ios/RuntimeHost/
│   ├── RuntimePaths.swift          共享根 /var/mobile/Library/MinisRuntime + 容器根回退
│   ├── RuntimeManifest.swift       清单 schema 3 的 Codable 模型
│   ├── RuntimeArchive.h/.c         gzip 流式解压(zlib,gzip 窗口)
│   ├── NativeShellExecutor.swift   posix_spawn + 进程组 + 双管道 + 超时 + 超长截断
│   ├── RuntimeInstaller.swift      下载/验哈希/ar+tar 解包/重签名/probe/翻链接
│   └── NativeShellBackend.swift    接 ISHExecutionCoordinator 的那一层
├── entitlements/Minis-TrollStore.entitlements
├── patches/patch_minis.py          改 pbxproj + 桥接头 + 协调器(幂等)
├── scripts/make_tipa.py            清理 → 瘦身 arm64 → 内层到外层签名 → 验 → 打包
└── .github/workflows/build-tipa.yml   macOS CI:原生依赖 → 取 helper → 补丁 → 编 → 打包
```

几个刻意的决定:

- **不做 `codex` 运行时**。Minis 有自己的 agent 循环和多 provider 层,再塞一个 MT-Agent 的宿主是互相打架。剩下六个工具链全要。
- **共享运行时根**。MT-Agent 也装在 `/var/mobile/Library/` 下。设备上已经跑过 MT-Agent 的,Minis 直接 probe 复用,不用再下 400 MB。
- **解包只吃 `tar.gz` 和 `ar`/deb**。清单里六个工具链全是 `.tar.gz`。`tar.xz`/`tar.zst` 明确报错而不是猜。
- **哈希先于解包**。截断的包能解出一棵看着像样的树,坏在几周后。
- **`current` 软链在 probe 通过后才翻**。半装的运行时永远不对 shell 可见。

---

## 4. 唯一的硬卡点:这台机器编不了

OpenMinis 的 iOS 端要:**macOS + Xcode 26 + iOS 26.2 SDK**。依赖链是
iSH(meson + clang)、FFmpeg(Metal toolchain)、rclone(Go 静态 xcframework)、
外加几个 SwiftPM binary target(ONNX 那套 VAD)。目标 `IPHONEOS_DEPLOYMENT_TARGET = 26.2`。

当前这台是 Windows,WSL 也没装发行版。**没有任何 Windows/Linux 路径能产出这个二进制。**
不是权限问题,是 Xcode 不存在。

两条路:

**A. GitHub Actions(`build-tipa.yml` 已写好)**
`macos-26` runner,Xcode 26 现成。冷编 ~35 分钟,热缓存 ~8 分钟,6 小时上限绰绰有余。
原生依赖打进 cache,第二次起就快了。
需要:一个 GitHub 仓库 + push 权限。

**B. 你有 Mac(本机 / 远程 / 云 Mac)**
我把 `patch_minis.py` + 构建脚本给你,`BUILDING.md` 里那五步原生依赖照跑,然后 `make_tipa.py` 打包。40–90 分钟。

---

## 5. 装完是什么样

- Minis 原来的东西全在:多 provider、skills、memory、workspace、设备工具、浏览器自动化、iCloud
- shell 工具从 iSH 换成真内核执行 —— `git clone`、`npm i`、`pip`、`clang`、`r2`、`make package` 全都能跑
- Theos 在设备上直接出 rootful/rootless/roothide 的 `.deb`
- Node 18 + npm,Python 3.13,OLLVM 混淆编译器,radare2 全套
- 保留 iSH 作为回退:运行时没装或权限没了,自动落回去,不会白屏

**代价**:这个包只能 TrollStore 装,或者装成越狱 deb。
App Store 装法、AltStore/SideStore 免费证书都装不上 —— `platform-application` 是平台专属权限,
启动会被内核拒。这是加环境的必付代价,绕不过。

---

## 6. 验证状态:哪些是证实过的,哪些还没有

没有 macOS 就意味着**没有编译过**。除此之外能验的,都验了。

已经证实的:

| 项 | 方法 | 结果 |
|---|---|---|
| CoreToolsRuntime 清单项 | 下载 + SHA-256 对照 manifest | `80f9fd75…` **完全一致** |
| 运行时包内部结构 | 解包 9.9 MB 真实 tar.gz | `bin/` + `manifest.json` 在根,17 个成员,`required_paths` 全部存在 |
| tar 成员类型 | python tarfile 审计 | 目录 1 / 普通文件 7 / 符号链接 9,**无 pax、无 GNU 长名、无 `..`、无绝对路径** |
| 符号链接语义 | `tar -tvzf` | `git-remote-https -> git-remote-http` 等全是**同目录相对路径**,我的读写实现按原名创建,成立 |
| gzip 状态机 | 用真实 9.9 MB 包按 64 KB 分块模拟 | 152 块,**输出与一次性解压逐字节相同**(23,920,640 B) |
| Swift 语法(5 个文件,2900 行) | tree-sitter-swift 解析 | **0 错误** |
| C 语法(解压 shim) | tree-sitter-c 解析 | **0 错误** |
| 补丁脚本 | 对真实 `project.pbxproj` 实跑 | 3 处编辑全部落位,target 归属正确,1281 个引用 id 全部有定义,括号 1368/1368 平衡 |
| entitlements | plistlib 解析 | 20 键合法,平台权限齐 |
| 打包脚本 | 造 stub `.app` 实跑 `--skip-signing` | 产出 `Payload/Minis.app/…` 结构正确,`_CodeSignature` 已清,嵌套 bundle 层级对 |
| MT-Agent 1.0.5 vs 1.0.6 | 三个 helper 二进制逐字节比对 | `bash.real`/`ca-filetool`/`codex-sign` **完全相同**,所以钉 1.0.5 不吃亏 |

这一轮里**改掉的真 bug**(不是风格问题):

- **gzip 解压状态机**:原来那版把"输入缓冲用完"当成"流被截断",任何超过 64 KB 的包都会解失败 ——
  也就是所有真实运行时包。现在 `RA_NEED_INPUT` 是独立的非错误返回。
- **`LineCollector` 丢输出**:只保留最后一个未换行的片段,`result.output` 对任何忽略逐行回调的调用方
  (probe、签名器)都是空字符串。现在整条流单独累积。
- **可用性探测的数据竞争**:`lazy var` 被主线程、安装器 actor、后台队列三方同时首次访问。改成锁保护。
- **挂载路径走 `URL(string:)`**:任何含空格的路径直接返回 nil,挂载被静默丢弃。改 `fileURLWithPath`。
- **`shellEnvironment()` 读 nil 清单**:首次拉取之前调用会得到一条没有任何运行时的 PATH,
  表现像"工具链装坏了"。现在回退读磁盘缓存。
- **`lipo -info` 判断写反**:原来那个 `arm64e` 条件会跳过**本该**瘦身的 fat 二进制。
- **`PRODUCT_BUNDLE_IDENTIFIER` 覆盖**:只改主 app 的 id 会让四个内嵌扩展指向不存在的主 app,embed 阶段校验失败。
  已移除。

还没有验证的(必须靠真机/真机编译):

- **能不能编译通过**。语法干净 ≠ 类型检查通过。`AnyActor`、`posix_spawn` 的指针参数、
  Swift 6 的严格并发 —— 这些只有 Xcode 能判。
- **`posix_spawn` 在平台签名下的实际行为**。理论上 `platform-application` 放开 `process-exec`,
  理论上 ad-hoc 签名的子二进制可执行。要真机确认。
- **`codex-sign` 的命令行契约**。我从字符串里读出 `--adhoc-only` / `--entitlements`,
  没跑过。跑失败会走"跳过重签名"分支,不会中断安装。
- **TheosRuntime 解包 980 MB 在手机上的耗时和内存**。这是最重的一步。
- **runner 上 iOS 26.2 SDK 在不在**。workflow 里做了自动降级(读到低于 26.2 的 SDK 就压低部署目标),
  但降级之后能不能编过没验过。

---

## 7. 第二轮挖出的两个结构性问题

### 7.1 manifest 不是完整描述,只是索引

`runtime-manifest.json` 里 `python` / `reverse_tools` / `theos` **没有 `install` 块,也没有 `sign_paths`**。
签名清单只在各自的 `metadata_url`(即 `*.bundle.json`)里。

只读索引的后果:这三个装完,文件躺在那儿,**一个二进制都没重签名**。iOS 上未签名的映像 exec 直接 EPERM,
而且报错里不会告诉你"你没签名"。这才是最贵的 bug —— 装完看着完全正常。

所以加了 `RuntimeBundle`,安装时先拉 `metadata_url` 并缓存,`RuntimePlan` 以描述符为准、索引兜底。
用真实文档跑了一遍推导:

| runtime | PATH | required | 签名目标 | shebang 改写 | probe |
|---|---|---|---|---|---|
| core_tools | `bin` | 11 | 6 | 0 | `bin/git` |
| node | `bin` | 23 | 2 (+1 adhoc) | 0 | `bin/node` |
| ollvm | `bin` | 5 | 1 | 0 | `bin/clang` |
| reverse_tools | `bin` | 2 | **8** | 0 | 无 |
| python | `.`(根) | 1 | **70** | 0 | 无 |
| theos | 4 条 | 2 | **362** | **109** | 无 |

修复前 reverse_tools / python / theos 的签名目标是 **0**。修复后 8 / 70 / 362。

顺带:theos 的 109 个 `#!/usr/bin/env perl` 脚本在 iOS 上根本跑不起来(iOS 没有 `/usr/bin/env`)。
现在按 `portable_shebangs` 清单重写首行并还原 `+x`。

### 7.2 `required` 不能当变量名

`RuntimePlan` 里我原本写了个 `var required: [String]`。它**能通过部分位置的解析,然后在 `case` 体里炸** ——
`required` 是 Swift 的声明修饰符,`required = [...]` 在 case body 里会被读成一个声明开头。

这是靠 tree-sitter 一路二分查出来的(14 个 ERROR 节点,删任何单行都不修复,最后靠整文件替换关键字定位)。
现在改成 `reqPaths`,并且 `preflight.py` 加了第 10 项检查:扫描 `var|let <声明修饰符>` 形式的变量声明,
`required` / `optional` / `prefix` / `weak` / `final` 这一批全查。已经用注入案例反向验证过能抓到。

同批顺手改名:`optional` → `isOptional`(manifest 模型)、`prefix` → `namePrefix`(tar 头解析)。

---

## 8. 第三轮:解码层静态契约校验,抓到一个会毁掉整个子系统的 bug

### 8.1 那条 bug

`InstallInstructions.signPathsWithoutEntitlements` 声明成**非可选** `[String]`。

真实文档里,6 个 `install` 块中只有 2 个带这个键 —— `core_tools` 没有。Swift 合成的 `Decodable`
遇到缺键直接 throw,而 `RuntimeSpec.install` 是**所有运行时一次性解码**的文档的一部分:

```
core_tools 缺一个键  →  InstallInstructions 抛错  →  RuntimeSpec 抛错
                    →  RuntimeManifest 整个失败  →  loadManifest() 抛错
                    →  运行时子系统整体不可用
```

不是"核心工具装不上",是**一个都装不上**,而且报错只有一个 `runtime manifest could not be loaded`,
看不出是哪一行。修法是手写 `init(from:)`,所有列表 `decodeIfPresent ?? []`:
缺一个列表的语义本来就是"这个运行时没有这些",不是"文档坏了"。

### 8.2 顺手删掉的死字段

`RuntimeSpec` 上原本声明了 `runtime_id` / `format` / `sign_paths` / `executables` /
`libraries` / `portable_shebangs`。这六个键**只存在于 bundle 描述符,index 里从来没有** ——
换句话说六个字段永远是 nil,读代码的人会以为 index 是权威源。全部移除,只留 bundle 侧。

同理 `RuntimeBundle.signPathsWithoutEntitlements` 也删了:它实际在 `install` 块里,不在顶层。

### 8.3 怎么发现的

试过装 Swift for Windows 想直接跑解码器,装了 6.4.1,`swiftc` / `swift-frontend` 一律
`0xC0000142`(DLL 初始化失败,165 MB 的 frontend 直接 crash),放弃。

改成**静态契约校验**,效果其实更好:

```
verify/contract-snapshot.json     从真实文档里抽出来的键名集合(只存键名,不存值和 URL)
scripts/contract_check.py         把 Swift 里的 Decodable 声明解析出来,对着快照验
```

两条规则:

- **keys** — CodingKeys 里写的每个 JSON 键,必须至少在一个真实文档里出现过。拼错立刻暴露。
- **fields** — 非可选属性,它的键必须在**每一个**同类文档里都在;缺一个就 throw。
  写了自定义 `init(from:)` 的,改成检查 init 里对这个键用的是 `decode` 还是 `decodeIfPresent`。

为了区分"某些文档有、某些没有",快照同时存**并集**和**交集**。交集就是非可选属性的硬要求。

第 8.1 条 bug 就是 `fields` 规则抓的,原文:

```
InstallInstructions.signPathsWithoutEntitlements is non-optional but
"sign_paths_without_entitlements" is missing from at least one real install
document — decoding will throw for that one
```

反向验证过:把 `decodeIfPresent` 改回 `decode`,检查立刻变红;改回来立刻变绿。

### 8.4 现在一共有三层验证

| 层 | 在哪跑 | 抓什么 | 耗时 |
|---|---|---|---|
| `preflight.py` 11 项 | 每次提交 / CI 第一步 | 语法、plist、pbxproj、关键字、解码契约 | ~20 s |
| `contract_check.py` | preflight 内 | 解码层 × 真实文档 | <1 s |
| `verify/main.swift` | **CI 里用真 `swiftc` 编译并运行** | 真的 `JSONDecoder` 跑真的文档 | ~5 s |

第三层是关键:它不是我的复刻,是**真的 Swift 解码**。CI 里先把三个纯 Foundation 文件编成可执行文件,
拉下真实 manifest 和 6 个描述符,跑一遍,把所有运行时的推导结果打成表打出来。
逆向那套"我以为是"的东西,到这一步才算被编译器承认。



