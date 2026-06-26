# SonarQube 用户使用指南

打开 SonarQube 并选择从 GitLab 登录, 登录后, 应当可以看到选项 `Import from
GitLab`.

点击该选项, 会看到 SonarQube 要求提供 PAT (Personal Access Token). 为了获取 PAT,
打开 GitLab, 生成或提供一个已经存在的 PAT. 权限勾选 `api` 即可.

把这个 PAT 填写进 SonarQube, 接下来就可以看到 SonarQube 列出你已经存在的仓库.

选择你要导入的仓库, 一直点继续, 最后通过配置 GitLab CI 的方式, 将 SonarQube
加入分析流程.
