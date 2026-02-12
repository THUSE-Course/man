# 小组管理

小组是 SECoder 平台中团队协作的基本单位。通过创建或加入小组，你可以与同学共同完成课程项目。

## 目录

- [创建小组](#创建小组)
- [编辑小组](#编辑小组)
- [邀请成员](#邀请成员)
- [接受邀请](#接受邀请)

---

## 创建小组

创建小组后，你将成为该小组的组长，负责管理小组成员和权限。

### 进入小组管理页面

登录后，通过侧边栏导航点击 **小组** 即可进入小组管理页面。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/create-group-desktop-01.png" alt="创建小组按钮 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/create-group-mobile-01.png" alt="创建小组按钮 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

### 开始创建小组

点击页面右上角的 **创建小组** 按钮开始创建流程。

### 填写小组信息

系统会弹出创建对话框，需要填写以下信息：

#### 小组名称

在 **小组名称** 输入框中填写小组的显示名称。这个名称将展示给所有用户，建议使用有意义的名称，例如课程名称或项目名称。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/create-group-desktop-02.png" alt="填写小组名称 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/create-group-mobile-02.png" alt="填写小组名称 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

#### 小组标识符

在 **小组标识符** 输入框中填写小组的唯一标识符。

**标识符要求**：
- 必须符合 [RFC 1035](https://tools.ietf.org/html/rfc1035) 标准
- 只能包含小写字母、数字和连字符（-）
- 必须以字母或数字开头和结尾
- 建议使用简短、易记的标识符

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/create-group-desktop-03.png" alt="填写小组标识符 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/create-group-mobile-03.png" alt="填写小组标识符 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

**示例**：
- 有效标识符：`group1`, `team-alpha`, `cs101-2024`
- 无效标识符：`Group-1`（含大写）, `-team`（以连字符开头）, `team_1`（含下划线）

### 完成创建

确认信息无误后，点击 **创建** 按钮完成小组创建。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/create-group-desktop-04.png" alt="创建按钮 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/create-group-mobile-04.png" alt="创建按钮 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

创建成功后，你将成为该小组的组长。在 **我的小组** 标签页中可以看到已创建的小组及其管理按钮。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/create-group-desktop-05.png" alt="创建成功 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/create-group-mobile-05.png" alt="创建成功 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

---

## 编辑小组

只有小组组长才能编辑小组信息。你可以修改小组的显示名称。

### 进入编辑界面

在 **我的小组** 标签页中，找到你创建的小组，点击 **编辑小组** 按钮。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/edit-group-desktop-01.png" alt="编辑小组按钮 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/edit-group-mobile-01.png" alt="编辑小组按钮 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

### 修改小组名称

在弹出的编辑对话框中，修改 **小组名称**。注意：小组标识符创建后无法修改。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/edit-group-desktop-02.png" alt="修改小组名称 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/edit-group-mobile-02.png" alt="修改小组名称 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

### 保存更改

点击 **保存更改** 按钮完成编辑。

---

## 邀请成员

只有小组组长才能邀请新成员加入小组。

### 发起邀请

在 **我的小组** 标签页中，找到你创建的小组，点击 **邀请加入小组** 按钮。

### 填写被邀请人学号

在弹出的对话框中，输入要邀请的用户的学号。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/invite-user-desktop-01.png" alt="填写被邀请人学号 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/invite-user-mobile-01.png" alt="填写被邀请人学号 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

### 发送邀请

点击 **发送邀请** 按钮完成邀请发送。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/invite-user-desktop-02.png" alt="发送邀请 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/invite-user-mobile-02.png" alt="发送邀请 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

---

## 接受邀请

收到小组邀请后，你可以选择接受或拒绝。

### 查看邀请

通过侧边栏导航点击 **邀请** 进入邀请管理页面。

### 接受邀请

在邀请列表中，找到想要加入的小组，点击 **接受** 按钮。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/accept-invite-desktop-01.png" alt="接受邀请 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/accept-invite-mobile-01.png" alt="接受邀请 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

### 拒绝邀请

如果不希望加入该小组，可以点击 **拒绝** 按钮。

<div style="display: flex; gap: 5%; align-items: center; justify-content: center;">
  <img src="assets/accept-invite-desktop-02.png" alt="拒绝邀请 - 电脑端" style="height: 350px; width: auto; object-fit: contain;">
  <img src="assets/accept-invite-mobile-02.png" alt="拒绝邀请 - 手机端" style="height: 350px; width: auto; object-fit: contain;">
</div>

接受邀请后，该小组将出现在你的 **我的小组** 列表中。
