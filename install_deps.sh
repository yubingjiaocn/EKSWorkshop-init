echo "Upgrading AWS CLI"
sudo yum remove aws-cli -y

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

echo "Installing jq"

sudo yum -y install jq gettext bash-completion moreutils

echo 'yq() {
  docker run --rm -i -v "${PWD}":/workdir mikefarah/yq "$@"
}' | tee -a ~/.bashrc && source ~/.bashrc

echo "Configuring AWS environment"

aws cloud9 update-environment  --environment-id $C9_PID --managed-credentials-action DISABLE
rm -vf ${HOME}/.aws/credentials

aws sts get-caller-identity --query Arn | grep eksworkshop-admin -q && echo "IAM role valid" || echo "IAM role NOT valid"

export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
export AZS=($(aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text --region $AWS_REGION))
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.endpoint" --output text)"

echo "export ACCOUNT_ID=${ACCOUNT_ID}" | tee -a ~/.bash_profile
echo "export AWS_ACCOUNT_ID=${ACCOUNT_ID}" | tee -a ~/.bash_profile
echo "export AWS_REGION=${AWS_REGION}" | tee -a ~/.bash_profile
echo "export CLUSTER_ENDPOINT=${CLUSTER_ENDPOINT}" | tee -a ~/.bash_profile

aws configure set default.region ${AWS_REGION}
aws configure get default.region

echo "Installing and Configuring kubectl"

sudo curl --silent --location -o /usr/local/bin/kubectl \
   https://s3.us-west-2.amazonaws.com/amazon-eks/1.21.5/2022-01-21/bin/linux/amd64/kubectl

sudo chmod +x /usr/local/bin/kubectl

export CLUSTER_NAME=eksworkshop-eksctl
echo "export CLUSTER_NAME=${CLUSTER_NAME}" | tee -a ~/.bash_profile

aws eks update-kubeconfig --name eksworkshop-eksctl --region ${AWS_REGION}

echo "Installing eksctl"

curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

echo "Installing Helm"

curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

helm version --short

echo "Creating OIDC Provider for Cluster" 

eksctl utils associate-iam-oidc-provider --region=${AWS_REGION} --cluster=${CLUSTER_NAME} --approve
