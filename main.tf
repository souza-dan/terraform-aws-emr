module "emr-hbase-s3" {
  source                         = "./modules/aws-emr-s3"
  bucket_name_for_hbase_root_dir = var.bucket_name_for_hbase_root_dir
  bucket_name_for_logs           = var.bucket_name_for_logs
  additional_tags                = var.additional_tags
}

module "emr-hbase-sgs" {
  source                        = "./modules/aws-emr-sgs"
  emr_managed_master_sg_name    = var.emr_managed_master_sg_name
  emr_managed_core_sg_name      = var.emr_managed_core_sg_name
  emr_additional_master_sg_name = var.emr_additional_master_sg_name
  emr_additional_core_sg_name   = var.emr_additional_core_sg_name
  emr_service_access_sg_name    = var.emr_service_access_sg_name
  vpc_id                        = var.vpc_id
  tamr_cidrs                    = var.tamr_cidrs
  tamr_sgs                      = var.tamr_sgs
  additional_tags               = var.additional_tags
}

module "emr-hbase-iam" {
  source                                  = "./modules/aws-emr-iam"
  aws_account_id                          = var.aws_account_id
  s3_bucket_name_for_hbase_logs           = module.emr-hbase-s3.s3_bucket_name_for_logs
  s3_bucket_name_for_hbase_root_directory = module.emr-hbase-s3.s3_bucket_name_for_hbase_rootdir
  emrfs_metadata_table_name               = var.emrfs_metadata_table_name
  aws_region_of_dynamodb_table            = var.aws_region_of_dynamodb_table
  emr_ec2_iam_policy_name                 = var.emr_ec2_iam_policy_name
  emr_service_iam_policy_name             = var.emr_service_iam_policy_name
  emr_service_role_name                   = var.emr_service_role_name
  emr_ec2_instance_profile_name           = var.emr_ec2_instance_profile_name
  emr_ec2_role_name                       = var.emr_ec2_role_name
  additional_tags                         = var.additional_tags
}

module "emrfs-dynamodb" {
  source                        = "./modules/aws-emr-emrfs"
  emrfs_metadata_read_capacity  = var.emrfs_metadata_read_capacity
  emrfs_metadata_write_capacity = var.emrfs_metadata_write_capacity
  emrfs_metadata_table_name     = var.emrfs_metadata_table_name
  tags                          = var.additional_tags
}

data "template_file" "load_file_to_upload" {
  template = file(var.emr_hbase_config_file_path)
  vars = {
    emrfs_metadata_read_capacity  = var.emrfs_metadata_read_capacity
    emrfs_metadata_write_capacity = var.emrfs_metadata_write_capacity
    emrfs_metadata_table_name     = var.emrfs_metadata_table_name
    emr_hbase_s3_bucket_root_dir  = module.emr-hbase-s3.s3_bucket_name_for_hbase_rootdir
  }
}

resource "aws_s3_bucket_object" "upload_config" {
  bucket       = module.emr-hbase-s3.s3_bucket_name_for_hbase_rootdir
  key          = "config.json"
  content      = data.template_file.load_file_to_upload.rendered
  content_type = "application/json"
}

data "template_file" "upload_hbase_config" {
  template = file("${path.module}/upload_hbase_config.sh")
  vars = {
    emr_hbase_s3_bucket_root_dir = module.emr-hbase-s3.s3_bucket_name_for_hbase_rootdir
    hbase_config_path            = var.hbase_config_path
    hadoop_config_path           = var.hadoop_config_path
  }
}

resource "aws_s3_bucket_object" "upload_bootstrap_script" {
  bucket  = module.emr-hbase-s3.s3_bucket_name_for_hbase_rootdir
  key     = "util/upload_hbase_config.sh"
  content = data.template_file.upload_hbase_config.rendered
}

resource "aws_emr_cluster" "emr-hbase" {
  depends_on     = [module.emrfs-dynamodb, aws_s3_bucket_object.upload_bootstrap_script]
  name           = var.cluster_name
  release_label  = var.release_label
  applications   = var.applications
  configurations = data.template_file.load_file_to_upload.rendered

  ec2_attributes {
    subnet_id                         = var.subnet_id
    emr_managed_master_security_group = module.emr-hbase-sgs.emr_managed_master_sg_id
    additional_master_security_groups = module.emr-hbase-sgs.emr_additional_master_sg_id
    emr_managed_slave_security_group  = module.emr-hbase-sgs.emr_managed_core_sg_id
    additional_slave_security_groups  = module.emr-hbase-sgs.emr_additional_core_sg_id
    service_access_security_group     = module.emr-hbase-sgs.emr_service_access_sg_id
    instance_profile                  = module.emr-hbase-iam.emr_ec2_instance_profile_arn
    key_name                          = var.key_pair_name
  }


  master_instance_group {
    name          = var.master_instance_group_name
    instance_type = var.master_instance_type
    # NOTE: value must be 1 or 3
    instance_count = var.master_group_instance_count
    ebs_config {
      size                 = var.master_ebs_size
      type                 = var.master_ebs_type
      volumes_per_instance = var.master_ebs_volumes_count
    }
  }
  core_instance_group {
    name           = var.core_instance_group_name
    instance_type  = var.core_instance_type
    instance_count = var.core_group_instance_count
    ebs_config {
      size                 = var.core_ebs_size
      type                 = var.core_ebs_type
      volumes_per_instance = var.core_ebs_volumes_count
    }
  }

  log_uri      = "s3n://${module.emr-hbase-s3.s3_bucket_name_for_logs}/"
  service_role = module.emr-hbase-iam.emr_service_role_arn

  # Upload HBase/Hadoop configuration to s3
  step {
    action_on_failure = "TERMINATE_CLUSTER"
    name              = "Sync HBase/Hadoop configuration to S3"

    hadoop_jar_step {
      jar = "command-runner.jar" # Native to AMI for running script using AWS CLI
      args = [
        "bash",
        "-c",
        " aws s3 cp s3://${module.emr-hbase-s3.s3_bucket_name_for_hbase_rootdir}/util/upload_hbase_config.sh .; chmod +x upload_hbase_config.sh; ./upload_hbase_config.sh"
      ]
    }
  }

  # Optional: ignore outside changes to running cluster steps
  lifecycle {
    ignore_changes = [step]
  }

  tags = var.additional_tags
}
