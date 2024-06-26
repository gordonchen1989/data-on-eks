#---------------------------------------------------------------
# IRSA for EBS CSI Driver
#---------------------------------------------------------------
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.34"
  role_name_prefix      = format("%s-%s-", local.name, "ebs-csi-driver")
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}
#---------------------------------------------------------------
# EKS Blueprints Kubernetes Addons
#---------------------------------------------------------------
module "eks_blueprints_addons" {
  # Short commit hash from 8th May using git rev-parse --short HEAD
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------
  # Amazon EKS Managed Add-ons
  #---------------------------------------
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns = {
      preserve = true
    }
    vpc-cni = {
      preserve = true
    }
    kube-proxy = {
      preserve = true
    }
  }
  #---------------------------------------
  # EFS CSI driver
  #---------------------------------------
  enable_aws_efs_csi_driver = true

  #---------------------------------------
  # CAUTION: This blueprint creates a PUBIC facing load balancer to show the Airflow Web UI for demos.
  # Please change this to a private load balancer if you are using this in production.
  #---------------------------------------
  enable_aws_load_balancer_controller = true

  #---------------------------------------
  # Metrics Server
  #---------------------------------------
  enable_metrics_server = true
  metrics_server = {
    values = [templatefile("${path.module}/helm-values/metrics-server-values.yaml", {})]
  }

  #---------------------------------------
  # Cluster Autoscaler
  #---------------------------------------
  enable_cluster_autoscaler = true
  cluster_autoscaler = {
    values = [templatefile("${path.module}/helm-values/cluster-autoscaler-values.yaml", {
      aws_region     = var.region,
      eks_cluster_id = module.eks.cluster_name
    })]
  }

  #---------------------------------------
  # Karpenter Autoscaler for EKS Cluster
  #---------------------------------------
  enable_karpenter                  = true
  karpenter_enable_spot_termination = true
  karpenter_node = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }
  karpenter = {
    chart_version       = "v0.34.0"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  #---------------------------------------
  # CloudWatch metrics for EKS
  #---------------------------------------
  enable_aws_cloudwatch_metrics = var.enable_aws_cloudwatch_metrics
  aws_cloudwatch_metrics = {
    values = [
      <<-EOT
        resources:
          limits:
            cpu: 500m
            memory: 2Gi
          requests:
            cpu: 200m
            memory: 1Gi

        # This toleration allows Daemonset pod to be scheduled on any node, regardless of their Taints.
        tolerations:
          - operator: Exists
      EOT
    ]
  }

  #---------------------------------------
  # AWS for FluentBit - DaemonSet
  #---------------------------------------
  enable_aws_for_fluentbit = var.enable_aws_for_fluentbit
  aws_for_fluentbit_cw_log_group = {
    create            = true
    use_name_prefix   = false
    name              = "/${local.name}/aws-fluentbit-logs" # Add-on creates this log group
    retention_in_days = 30
  }
  aws_for_fluentbit = {
    create_namespace = true
    namespace        = "aws-for-fluentbit"
    create_role      = true
    role_policies    = { "policy1" = aws_iam_policy.fluentbit.arn }
    values = [templatefile("${path.module}/helm-values/aws-for-fluentbit-values.yaml", {
      region               = local.region,
      cloudwatch_log_group = "/${local.name}/aws-fluentbit-logs"
      s3_bucket_name       = module.fluentbit_s3_bucket.s3_bucket_id
      cluster_name         = module.eks.cluster_name
    })]
  }

  #---------------------------------------
  # Prommetheus and Grafana stack
  #---------------------------------------
  #---------------------------------------------------------------
  # Install Kafka Montoring Stack with Prometheus and Grafana
  # 1- Grafana port-forward `kubectl port-forward svc/kube-prometheus-stack-grafana 8080:80 -n kube-prometheus-stack`
  # 2- Grafana Admin user: admin
  # 3- Get admin user password: `aws secretsmanager get-secret-value --secret-id <output.grafana_secret_name> --region $AWS_REGION --query "SecretString" --output text`
  #---------------------------------------------------------------
  enable_kube_prometheus_stack = var.enable_kube_prometheus_stack
  kube_prometheus_stack = {
    values = [
      var.enable_amazon_prometheus ? templatefile("${path.module}/helm-values/kube-prometheus-amp-enable.yaml", {
        region              = local.region
        amp_sa              = local.amp_ingest_service_account
        amp_irsa            = module.amp_ingest_irsa[0].iam_role_arn
        amp_remotewrite_url = "https://aps-workspaces.${local.region}.amazonaws.com/workspaces/${aws_prometheus_workspace.amp[0].id}/api/v1/remote_write"
        amp_url             = "https://aps-workspaces.${local.region}.amazonaws.com/workspaces/${aws_prometheus_workspace.amp[0].id}"
      }) : templatefile("${path.module}/helm-values/kube-prometheus.yaml", {})
    ]
    chart_version = "48.2.3"
    set_sensitive = [
      {
        name  = "grafana.adminPassword"
        value = data.aws_secretsmanager_secret_version.admin_password_version.secret_string
      }
    ],
  }

  tags = local.tags
}



#---------------------------------------------------------------
# Grafana Admin credentials resources
#---------------------------------------------------------------
resource "random_password" "grafana" {
  length           = 16
  special          = true
  override_special = "@_"
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${local.name}-grafana"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = random_password.grafana.result
}

data "aws_secretsmanager_secret_version" "admin_password_version" {
  secret_id  = aws_secretsmanager_secret.grafana.id
  depends_on = [aws_secretsmanager_secret_version.grafana]
}

#---------------------------------------------------------------
# IAM Policy for FluentBit Add-on
#---------------------------------------------------------------
resource "aws_iam_policy" "fluentbit" {
  description = "IAM policy policy for FluentBit"
  name        = "${local.name}-fluentbit-additional"
  policy      = data.aws_iam_policy_document.fluent_bit.json
}

#---------------------------------------------------------------
# S3 log bucket for FluentBit
#---------------------------------------------------------------
#tfsec:ignore:*
module "fluentbit_s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket_prefix = "${local.name}-spark-logs-"
  # For example only - please evaluate for your environment
  force_destroy = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# IAM policy for FluentBit
#---------------------------------------------------------------
data "aws_iam_policy_document" "fluent_bit" {
  statement {
    sid       = ""
    effect    = "Allow"
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${module.fluentbit_s3_bucket.s3_bucket_id}/*"]

    actions = [
      "s3:ListBucket",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetObject",
      "s3:GetObjectAcl",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion"
    ]
  }
}

#---------------------------------------
# GP3 Storage Class for EBS CSI Driver
#---------------------------------------
data "kubectl_path_documents" "ebs_gp3_sc" {
  pattern = "${path.module}/gp3.yaml"
}

resource "kubectl_manifest" "ebs_gp3_sc" {
  for_each  = toset(data.kubectl_path_documents.ebs_gp3_sc.documents)
  yaml_body = each.value

  depends_on = [module.eks_blueprints_addons]
}

#---------------------------------------
# Karpenter Provisioners for Spark workloads
# Workaround. https://github.com/gavinbunney/terraform-provider-kubectl/issues/61#issuecomment-914285395
# https://github.com/gavinbunney/terraform-provider-kubectl/issues/58#issuecomment-718174177
#---------------------------------------
data "kubectl_path_documents" "karpenter_nodepools" {
  pattern = "${path.module}/karpenter-nodepools/*.yaml"
  vars = {
    azs            = local.region
    eks_cluster_id = module.eks.cluster_name
    ec2_node_role  = module.eks_blueprints_addons.karpenter.node_iam_role_name
  }
}

resource "kubectl_manifest" "karpenter_nodepools" {
  count = length(
    flatten(
      toset([
        for f in fileset(".", data.kubectl_path_documents.karpenter_nodepools.pattern) : split("\n---\n", file(f))
        ]
      )
    )
  )
  
  yaml_body = element(data.kubectl_path_documents.karpenter_nodepools.documents, count.index)

  depends_on = [module.eks_blueprints_addons]
}


###############################################################
#---------------------------------------------------------------
# Data on EKS Kubernetes Addons
#---------------------------------------------------------------
###############################################################

module "eks_data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "~> 1.31" # ensure to update this to the latest/desired version

  oidc_provider_arn = module.eks.oidc_provider_arn
  
  #---------------------------------------------------------------
  # Kubecost Add-on
  #---------------------------------------------------------------
  # Note: Kubecost add-on depdends on Kube Prometheus Stack add-on for storing the metrics
  enable_kubecost = var.enable_kubecost
  kubecost_helm_config = {
    values              = [templatefile("${path.module}/helm-values/kubecost-values.yaml", {})]
    version             = "1.106.0"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  #---------------------------------------------------------------
  # Spark Operator Add-on
  #---------------------------------------------------------------
  enable_spark_operator = var.enable_spark_tools_team_a
  spark_operator_helm_config = {
    values = [templatefile("${path.module}/helm-values/spark-operator-values.yaml", {})]
  }

  #---------------------------------------------------------------
  # Spark History Server Add-on
  #---------------------------------------------------------------
  enable_spark_history_server = var.enable_spark_tools_team_a
  spark_history_server_helm_config = {
    values = [
      <<-EOT
      sparkHistoryOpts: "-Dspark.history.fs.logDirectory=s3a://${try(module.spark_s3_bucket[0].s3_bucket_id, "")}/${try(aws_s3_object.spark-event-logs[0].key, "")}"
      EOT
    ]
  }
  
  #---------------------------------------------------------------
  # Apache YuniKorn Add-on
  #---------------------------------------------------------------
  enable_yunikorn = var.enable_yunikorn
  yunikorn_helm_config = {
    values             = [templatefile("${path.module}/helm-values/yunikorn-values.yaml", {
      image_version    = "1.2.0"
    })]
  }


  #---------------------------------------------------------------
  # Airflow Add-on
  #---------------------------------------------------------------
  enable_airflow = var.enable_airflow
  airflow_helm_config = {
    namespace = try(kubernetes_namespace_v1.airflow[0].metadata[0].name, local.airflow_namespace)
    version   = "1.12.0"
    values = [templatefile("${path.module}/helm-values/airflow-values.yaml", {
      # Airflow Postgres RDS Config
      airflow_db_user = local.airflow_name
      airflow_db_pass = try(sensitive(aws_secretsmanager_secret_version.postgres[0].secret_string), "")
      airflow_db_name = try(module.db[0].db_instance_name, "")
      airflow_db_host = try(element(split(":", module.db[0].db_instance_endpoint), 0), "")
      #Service Accounts
      worker_service_account    = try(kubernetes_service_account_v1.airflow_worker[0].metadata[0].name, local.airflow_workers_service_account)
      scheduler_service_account = try(kubernetes_service_account_v1.airflow_scheduler[0].metadata[0].name, local.airflow_scheduler_service_account)
      webserver_service_account = try(kubernetes_service_account_v1.airflow_webserver[0].metadata[0].name, local.airflow_webserver_service_account)
      # S3 bucket config for Logs
      s3_bucket_name        = try(module.airflow_s3_bucket[0].s3_bucket_id, "")
      webserver_secret_name = local.airflow_webserver_secret_name
      efs_pvc               = local.efs_pvc
      aws_region            = local.region
      account_id            = local.account_id
    })]
  }

}  
