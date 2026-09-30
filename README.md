# 提示词本

一个离线的 Windows 桌面小工具：写提示词、保存、搜索，再一键复制使用。

## 打开

把 `PromptDesk.ps1` 和 `Start.cmd` 放在同一个文件夹，双击 `Start.cmd`。使用 Windows 自带的 PowerShell，不需要安装 Python 或联网。

## 使用

- 点“新建”，填写标题和提示词内容，再点“保存”。
- 左侧输入关键词，可搜索标题和内容。
- 选中一条提示词，点“复制内容”即可粘贴到其他软件。
- 修改已有内容后点“保存”。切换或关闭时若有未保存的内容，程序会先提醒。

提示词保存在 `%APPDATA%\PromptDesk\prompts.json`，同目录的 `prompts.json.bak` 是最近一次保存前的备份。关闭程序不会删除这些数据。

## 自检

在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\PromptDesk.ps1 -SelfTest
```

自检只使用临时文件，不会修改你的提示词。

