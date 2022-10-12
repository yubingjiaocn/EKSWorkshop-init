# 利用Karpenter快速进行弹性伸缩

## 安装依赖

我们已经在实验环境预置了EKS 1.21集群和一个Cloud9在线实验环境，但该环境未预装Kubernetes需要的客户端软件。运行以下命令进行安装：

```bash
wget https://raw.githubusercontent.com/yubingjiaocn/EKSWorkshop-init/main/install_deps.sh
chmod +x install_deps.sh
./install_deps.sh
source ~/.bashrc
```

以上命令会安装AWS CLI V2, kubectl, helm和其他依赖组件。安装完成后，打开一个新的终端窗口以确保环境变量正确配置。

## 安装Karpenter

我们参考[Karpenter官方文档](https://karpenter.sh/v0.14.0/getting-started/getting-started-with-eksctl/)进行安装。

在安装之前，需要配置一些环境变量。运行如下命令：

```bash
export KARPENTER_VERSION=v0.18.0
```

### 配置IAM角色

运行以下命令，创建Karpenter使用的IAM策略。这些IAM策略允许Karpenter列出，创建和删除EC2：

```bash
TEMPOUT=$(mktemp)

curl -fsSL https://karpenter.sh/"${KARPENTER_VERSION}"/getting-started/getting-started-with-eksctl/cloudformation.yaml  > $TEMPOUT \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```
这条命令预计会运行2-3分钟，您可以打开CloudFormation控制台查看部署状况。

Karpenter需要更新`aws-auth`，使得新创建的节点可以连接到现有的EKS集群。运行以下命令：

```bash
eksctl create iamidentitymapping \
  --username system:node:{{EC2PrivateDNSName}} \
  --cluster "${CLUSTER_NAME}" \
  --arn "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --group system:bootstrappers \
  --group system:nodes
```
创建Karpenter Controller所需的IAM Role和Service Account: 
```bash
eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --name karpenter --namespace karpenter \
  --role-name "${CLUSTER_NAME}-karpenter" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --role-only \
  --approve

export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"
echo $KARPENTER_IAM_ROLE_ARN

```

您应该能看到类似于`arn:aws:iam::645289445021:role/eksworkshop-eksctl-karpenter` 的输出。

运行以下命令以启用Spot实例支持：

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
# If the role has already been successfully created, you will see:
# An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account, please try a different suffix.
```

*注意：这条命令报错是正常现象，此时继续即可。*

### 安装Karpenter

运行以下命令，使用Helm安装Karpenter: 
```bash
helm repo add karpenter https://charts.karpenter.sh/
helm repo update
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} --namespace karpenter --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set clusterName=${CLUSTER_NAME} \
  --set clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --wait # for the defaulting webhook to install before creating a Provisioner
```

当看到`DEPLOYED`时，Karpenter安装完成。您可运行`kubectl get pod -n karpenter`确认Karpenter是否正确运行。

## 创建Provider

在部署节点之前，我们需要创建Provider。Provider指定了新创建节点的实例类型，容量模式，子网等设置。运行以下命令：

```yaml
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  labels:
    intent: apps
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]
    - key: karpenter.k8s.aws/instance-size
      operator: NotIn
      values: [nano, micro, small, medium, large]
  consolidation:
    enabled: true    
  limits:
    resources:
      cpu: 1000
      memory: 1000Gi
  providerRef:
    name: default
---
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  subnetSelector:
    alpha.eksctl.io/cluster-name: ${CLUSTER_NAME}
  securityGroupSelector:
    alpha.eksctl.io/cluster-name: ${CLUSTER_NAME}
  tags:
    KarpenerProvisionerName: "default"
    NodeType: "karpenter-workshop"
    IntentLabel: "apps"
EOF
```
## 创建示例Pod

运行以下命令创建一个资源消耗为1C/1.5G的示例Pod: 

```yaml
cat <<EOF > inflate.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      nodeSelector:
        intent: apps
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.2
          resources:
            requests:
              cpu: 1
              memory: 1.5Gi
EOF
kubectl apply -f inflate.yaml
```

我们虽然创建了一个Deployment，但是未创建任何Pod。我们可以利用`kubectl scale`命令调整Pod数量，观察节点变化：

```bash
kubectl scale deployment inflate --replicas=1
```

此时运行`kubectl get node`，即可看到节点数量变化。
