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
    - test-u-2026000000.@@SECODER_BASE_DOMAIN@@
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

由于 GitLab Runner 访问外部网络不稳定, 不要在 `.gitlab-ci.yml` 中使用
`include:` 远程引用这些模板. 请打开对应的模板 YAML 文件, 将内容直接复制到
项目 `.gitlab-ci.yml` 中, 再定义自己的作业.

通常做法是:

1. 将需要的模板 YAML 内容内联复制到项目 `.gitlab-ci.yml`
2. 新建一个作业 `extends: .kustomize`
3. 设置 `KUSTOMIZE_PATH` 指向你的 `kustomization.yaml` 所在目录
4. 提交代码后, GitLab Pipeline 自动执行部署

示例:

```yaml
.kustomize:
  image:
    name: alpine/k8s:1.35.1
    entrypoint: [""]
  stage: deploy
  variables:
    KUSTOMIZE_PATH: .
  script:
    - |
      set -eu
      : "${TOKEN:?TOKEN is required}"
      : "${KUBERNETES_SERVICE_HOST:?not running in k8s?}"
      : "${KUBERNETES_SERVICE_PORT:?not running in k8s?}"
      export KUBECTL_APPLYSET=true
      kubectl \
        --token="${TOKEN}" \
        -n "${NAMESPACE}" \
        apply -k "${KUSTOMIZE_PATH:-.}" \
        --applyset="gitops-ci-${CI_PROJECT_PATH_SLUG:-unknown}" \
        --prune

deploy:
  extends: .kustomize
```

## 使用 BuildKit 缓存

如果项目用 BuildKit 构建镜像, 可以把缓存导出到同一个 GitLab Container
Registry. 这样第一次 Pipeline 会创建缓存, 后续 Pipeline 会复用 Dockerfile
前面没有变化的层, 例如依赖安装步骤.

在 `.gitlab-ci.yml` 的 BuildKit 作业中增加一个缓存镜像引用:

```yaml
variables:
  BUILDKIT_CACHE_REF: $CI_REGISTRY_IMAGE:buildcache
```

然后在 `buildctl-daemonless.sh build` 命令里同时导入和导出缓存:

```sh
buildctl-daemonless.sh build \
  --frontend "${BUILDKIT_FRONTEND}" \
  --local context="${BUILDKIT_CONTEXT}" \
  --local dockerfile="${BUILDKIT_DOCKERFILE_DIR}" \
  --import-cache type=registry,ref="${BUILDKIT_CACHE_REF}" \
  --export-cache type=registry,ref="${BUILDKIT_CACHE_REF}",mode=max \
  --output type="${BUILDKIT_OUTPUT_TYPE}",name="${BUILDKIT_IMAGE_NAME}:${BUILDKIT_IMAGE_TAG}",push="${BUILDKIT_PUSH}"
```

缓存和最终镜像使用同一个 Registry 登录信息, 因此通常不需要额外配置凭据.
如果多个分支都会构建, 可以把缓存引用改成
`$CI_REGISTRY_IMAGE:buildcache-$CI_COMMIT_REF_SLUG`, 避免不同分支互相覆盖缓存.

## 本地预览合成结果

在提交前, 建议先在本地预览:

```bash
kubectl kustomize deploy/minimal
```

这个命令只会输出最终 YAML, 不会实际修改集群.
