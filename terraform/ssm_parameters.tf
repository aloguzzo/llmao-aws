resource "aws_ssm_parameter" "cw_agent_config" {
  name        = "/app/cloudwatch/agent_config"
  description = "Reduced CloudWatch Agent JSON config for llm single EC2 (lower cost)"
  type        = "String"
  tier        = "Standard"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 300     # 5 minutes
      logfile                     = "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
      debug                       = false
    }
    metrics = {
      append_dimensions = {
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
        ImageId              = "$${aws:ImageId}"
        InstanceId           = "$${aws:InstanceId}"
        InstanceType         = "$${aws:InstanceType}"
      }
      aggregation_dimensions = [["InstanceId"]]
      metrics_collected = {
        cpu = {
          measurement = ["cpu_usage_user", "cpu_usage_system", "cpu_usage_idle"]
          resources   = ["*"]
          totalcpu    = true   # keep only aggregate total
        }
        mem = {
          measurement = ["mem_used_percent"]  # keep only used percent
        }
        disk = {
          measurement = ["used_percent"]
          resources   = ["/"]                  # only root filesystem
          ignore_file_system_types = ["sysfs", "devtmpfs", "overlay", "squashfs", "tracefs", "tmpfs"]
        }
        # removed 'net' and other high cardinality metrics to reduce datapoints
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path        = "/var/log/syslog"
              log_group_name   = "/ec2/llm-stack/system"
              log_stream_name  = "{instance_id}-syslog"
              timestamp_format = "%b %d %H:%M:%S"
            }
            # Docker container logs intentionally removed to reduce ingestion cost
          ]
        }
      }
      force_flush_interval = 5
    }
  })

  tags = {
    Application = "llm-stack"
    Component   = "cloudwatch-agent"
  }
}