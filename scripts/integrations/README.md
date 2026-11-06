# DeskCapture本地工作流启动适配

先在DeskCapture“历史→工作流”保存流程，再复制已保存链接。`deskcapture://workflow?id=<UUID>`只打开最近保存的本地流程；捕获、运行和交付在可见工作流界面触发。URL不接受运行命令、输入/输出文件路径或自定义代码。未保存的ID报错，不会静默运行其他动作。

macOS快捷指令可以用“打开URL”打开复制的链接；也可在“运行Shell脚本”中调用`deskcapture-workflow.sh`并传入该UUID。脚本只校验参数并打开系统URL，不修改快捷指令库。当前没有原生AppIntent，也不提供后台无人值守捕获/导出。

Raycast适配文件为`raycast-deskcapture-workflow.sh`，采用官方Script Commands元数据。通过Raycast自己的Add Script Directory载入适配目录后，输入已保存UUID即可打开工作流。本次仅交付脚本，没有自动更改用户Raycast或快捷指令配置，也未把脚本存在当作运行验收。

实际适配入口、无效ID、应用未启动、当前签名和系统URL处理器的对应关系均待最终统一验收。脚本只应从受信任的本地工作流ID启动；不会把任意输入拼成Shell代码。

参考：[Raycast官方Script Commands文档](https://github.com/raycast/script-commands#metadata)。
