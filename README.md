# 课讯

一个在 Mac 本机运行的北大课程动态整理工具。把教学网公告、作业、课程内容、课程大纲、课程实录和成绩放在同一个时间线，并提醒新动态。

![课讯图标](assets/icon.png)

> 个人开源项目，非北京大学官方应用。课程网站改版后，部分同步功能可能需要维护。

## 下载与安装

从 [Releases 页面](https://github.com/qqqqingmo/pku-coursewatch/releases)下载最新版 ZIP，解压后将“课讯.app”拖入“应用程序”文件夹。支持 macOS 13 或更高版本，以及 Apple 芯片和 Intel 芯片 Mac。

应用使用临时签名，未经过 Apple 公证。首次启动如被 macOS 拦截，请在 Finder 中右键点击应用并选择“打开”；若仍被拦截，到“系统设置 → 隐私与安全性”中选择“仍要打开”。

## 开始使用

1. 打开应用，进入左侧“设置 → 自动登录设置”，填入**你自己的**校园卡账号和密码。
2. 回到首页，点击“立即同步”。教学网当前学期课程会出现在左侧，勾选想关注的课程。
3. 如需检查[北大问学](https://class.pku.edu.cn/)作业，在“设置 → 外部课程同步”启用问学。应用会按已勾选课程的名称匹配问学中的本学期课程；名称差异较大时可能匹配不到。
4. 如需检查 Gradescope，先在“设置 → Gradescope 自动登录”填入**你自己的** Gradescope 账号，再到“外部课程同步”为相应教学网课程填写 Gradescope 课程网址或编号。只有已配置且已勾选的课程会同步。

首次同步建立基线，以后发现的新内容才提醒。应用每天 09:00 自动检查一次；Mac 关机或离线时会在下次启动后补查，也可随时点“立即同步”。

## 功能

- 按课程、类型和时间筛选动态；区分未读、待完成。
- 给每条动态添加私人备注或置顶；手动补充未在网站发布的作业。
- 将有截止时间的作业加入 macOS “课业”日历，并按实际截止时间设置提前两天、一天、两小时提醒。
- 教学网使用校园卡自动登录；问学共用校园卡账号。网站要求验证码或二次验证时，可在设置里手动恢复登录。
- Gradescope 课程由每位使用者自行配置；没有预设任何人的课程编号。

## 隐私与数据

仓库及 Release 安装包不包含任何使用者的账号、密码、Cookie、课程数据、备注或日历事件。运行后，应用将数据保存在当前 Mac 用户的 `~/Library/Application Support/CourseWatch/`，其中 `data.json` 保存课程和状态，`credentials.json` 保存自动登录账号。账号文件权限设为仅当前 Mac 用户可读（`0600`），但未额外加密。请勿上传或分享该目录，也不要在 Issue 中粘贴账号、Cookie 或课程页面原文。

网页登录会话由 macOS WebKit 存储在本机。应用只访问教学网、北大问学和用户配置的 Gradescope 课程；具体网页读取逻辑可查看 `CourseWatch/` 中的源码。

## 从源码构建

在 Mac 上安装 Xcode Command Line Tools，然后运行：

```bash
xcode-select --install
zsh CourseWatch/build.sh
```

生成的应用位于 `dist/课讯.app`。如需同时包含 Apple 芯片与 Intel 芯片版本：

```bash
COURSEWATCH_ARCHS=universal zsh CourseWatch/build.sh
```

可用 `node --test tests/*.test.mjs` 检查问学课程匹配逻辑。

## 已知限制

- 问学课程按名称自动匹配；名称差异较大时可能遗漏。Gradescope 需要手动配置课程编号。
- 网站更改网页结构、登录流程或访问限制后，同步可能失效。
- 应用不是实时推送，自动检查时间为每天 09:00。

代码按 [MIT License](LICENSE) 开源。欢迎提交 Issue 或 Pull Request；反馈问题时请删去私人信息。
