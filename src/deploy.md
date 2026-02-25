# 部署应用

SECoder 平台使用 `kustomization.yaml` 管理部署配置, 并通过 GitLab
CI/CD 自动部署.

## 准备工作

在 GitLab 项目里配置 2 个 CI/CD 变量:

- `TOKEN`: 从 SECoder 的 **个人资料** 页面复制 API 令牌
- `NAMESPACE`: 你的命名空间, 格式固定为 `u-<学号>`

示例: 学号是 `2026000000`, 则 `NAMESPACE=u-2026000000`.

## 先理解 `kustomization.yaml`

`kustomization.yaml` 是部署入口文件:

- `resources`: 基础资源从哪里来
- `patches`: 你要覆盖哪些字段

示例来自:
[secoder-tmpl/examples/minimal](https://github.com/THUSE-Course/secoder-tmpl/blob/master/examples/minimal/kustomization.yaml)

```yaml
resources:
  - git@github.com:THUSE-Course/secoder-tmpl.git/deploy/basic/
patches:
  - path: route.yaml
  - path: frontend.yaml
  - path: backend.yaml
```

这表示:

1. 先读取 `deploy/basic/` 的默认资源
2. 再应用 3 个补丁

## 最小补丁示例

### `route.yaml`: 绑定访问域名

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route
spec:
  hostnames:
    - test-u-2026000000.secoder.net
```

### `frontend.yaml`: 添加环境变量

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  template:
    spec:
      containers:
        - name: nginx
          env:
            - name: EXAMPLE_KEY
              value: hello,world
```

### `backend.yaml`: 指定镜像版本

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
        - name: backend
          image: nginx:1.29.5-alpine3.23
```

## 在 GitLab CI/CD 中部署

SECoder 模板的 CI 文件位于:
[secoder-tmpl/gitlab-ci](https://github.com/THUSE-Course/secoder-tmpl/blob/master/gitlab-ci/kustomize.yml)

通常做法是:

1. 在项目 `.gitlab-ci.yml` 中 `include` 模板
2. 新建一个作业 `extends: .kustomize`
3. 设置 `KUSTOMIZE_PATH` 指向你的 `kustomization.yaml` 所在目录
4. 提交代码后, GitLab Pipeline 自动执行部署

示例:

```yaml
include:
  - remote: "https://raw.githubusercontent.com/THUSE-Course/secoder-tmpl/master/gitlab-ci/kustomize.yml"

deploy:
  extends: .kustomize
```

## 本地预览合成结果

在提交前, 建议先在本地预览:

```bash
kubectl kustomize deploy/minimal
```

这个命令只会输出最终 YAML, 不会实际修改集群.
