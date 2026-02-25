# 管理

SECoder 既可以指整个包含 Kubernetes 集群在内的平台,
也可以指集群中负责用户管理的前后端.

没有特别说明的话, 部署 SECdoer 的含义是配置并调试集群在内的整个平台.

## 部署 SECoder

### 前置要求

- 拥有校园网 IPv4 或 IPv6 地址, SECoder 至少要使用 `22`, `443` 端口.
  尽管可以在应用层进行负载均衡, 但更推荐的做法是进行端口绑定或裸机监听,
  在这样的配置下 SECoder 才能够路由用户的部署业务并且对
  GitLab SSH 协议的 TCP 流量进行转发.
- NFS 存储
- SECoder 域名的 DNS 编辑权限. Kubernetes 集群的 cert-manager
  可以方便地自动更新证书并且保证服务不中断
- 至少两台虚拟机

### Kubernetes 集群

新版本 SECoder 的开发在 2026 年初完成, 使用 Debian 13 以及当时的最新 Kubernetes
版本 1.35, 但一般来说, 版本并不重要, 可以更新.

经过实验, 纯 IPv6 的集群也可以正常工作, 只需要提供合适的 DNS64 与 NAT64.

管理员应当首先准备 NFS 文件系统, 以便满足集群后续的存储需求.
其次准备 Debian 13 操作系统并安装
[`kubeadm`](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/).

`kubeadm` 可以通过配置文件首先启动一个控制面, 考虑课程的需要,
部署单个控制面节点 (分配 4c4g) 即可.

在这之外, 部署至少一个工作节点.
通过以下配置和命令初始化控制面节点 (称为 node):

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.128.1.111
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
apiServer:
  certSANs:
    - c.secoder.net
networking:
  dnsDomain: cluster.local
  podSubnet: 10.16.0.0/12
  serviceSubnet: 10.32.0.0/12
controlPlaneEndpoint: 10.128.1.111:6443
clusterName: secoder
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 512
```

或者 IPv6 单栈:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "2001:db8:0:0:2::2"
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta4
clusterName: tunet
kind: ClusterConfiguration
controlPlaneEndpoint: "[2001:db8:0:0:2::2]:6443"
apiServer:
  certSANs:
    - c.secoder.net
networking:
  podSubnet: "2001:db8:0:0:3::/96"
  serviceSubnet: "2001:db8:0:0:3:1::/108"
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size-ipv6
      value: "100"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 512
```

### FluxCD

为了保持不同学期之间的一致性, SECoder 采用 GitOps 的方式部署集群配置.
FluxCD 是将配置文件同步为集群资源的有力工具. 管理员需要[下载 `flux`
工具](https://github.com/fluxcd/flux2/releases)以便初始化 FluxCD.

### GitLab

因为 GitLab 的 Helm Chart 所能覆盖的配置有限, 在确认 GitLab 正确启动后,
管理员需要登录 root 用户并配置下列设置:

通过以下命令获取 root 用户的密码:

```sh
kubectl get secrets -n devops \
gitlab-gitlab-initial-root-password \
-o jsonpath="{.data.password}" | base64 -d
```

1. 禁止注册

   进入 `Admin > Settings > General > Sign-up restrictions`,
   - 禁用 `Sign-up enabled`

   点击 `Save changes` 保存选择.

1. 禁止密码登录

   进入 `Admin > Settings > General > Sign-in restrictions`
   - 启用 `Allow password authentication for the web interface`
     (必须, 否则 root 用户无法登录)
   - 禁用 `Allow password authentication for Git over HTTP(S)`
   - 启用 `Disable password authentication for users with an SSO identity`

   同样注意保存设置

1. 设置仓库

   进入 `Admin > Settings > Repository > Default branch`
   - 设置初始分支为 `master`
   - 允许 `Maintainers` push 到受保护分支
   - 允许 `Developers + Maintainers` merge
   - 启用 `Allow developers to push to the initial commit`

   同样注意保存设置

1. 配置 CI/CD

   进入 `Admin > Settings > CI/CD > Continuous Integration and Deployment`
   - 禁用 `Default to Auto DevOps pipeline for all projects`

   同样注意保存设置

1. 创建 Access token

   进入 `User settings > Personal access tokens`
   创建名为 `rw` 的 token, 设置 scope 为:
   - `api`

1. 创建顶级分组

   以 root 身份创建 `g2026`, `u2026` 顶级组.
   组名在后续配置中会用到.

### SECoder 前后端

助教配置后端时, 需准备学期内选课学生的学号与初始密码, 格式为:

```json
[
  {
    "id": "2001",
    "passwd": "Bfwae"
  },
  {
    "id": "2002",
    "passwd": "Afaewab"
  }
]
```
