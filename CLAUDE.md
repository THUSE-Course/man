This is the documentation for SECoder, a next-generation platform for Software Engineering lesson teaching.
这是软件工程下一代课程平台 SECoder 的文档.

用中文作为文档的主要语言, 用深色模式作为主要的色彩模式. 用 900\*600 的分辨率作为电脑端分辨率截图; 用 450\*800 的分辨率作为手机端分辨率截图. 在编写文档的时候, 你应当将前端语言设置为中文.

在写文档的时候, 你应该通过修改对应元素的 CSS 在需要点击或者互动的控件上添加 **红色边框** (如果按钮本身是红色, 那就用橙黄色) 用于标识, 在添加之后请确认添加的 CSS 正确渲染, 一次截图的时候最多添加一个标记, 在截图之后应该清除对应的标记. 请对每一个需要操作的位置截图说明, 截图的存放位置是同目录的 assets/ 文件夹, 同时对电脑端和手机端截图, 在文档中高度一样放在一排, 参考:

```html
<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/login-desktop-02.png" alt="填写登录信息 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/login-mobile-02.png" alt="填写登录信息 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>
```

请使用简洁专业的语言写文档. 文档的受众是本系统的用户 (大学生).

系统的 URL 为 https://backend.t.adamanteye.cc , 测试用户为 2001 和 2003, 密码均为 s001Afwae , 平时用 2001, 遇到需要多用户的演示可以用 2003. 如果你不知道接下来应该如何操作, 可以询问我.
