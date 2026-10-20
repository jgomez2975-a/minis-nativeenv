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
