resource "aws_ssm_parameter" "cw_agent_config" {
  name        = "/app/cloudwatch/agent_config"
  description = "CloudWatch Agent JSON config for llm single EC2"
  type        = "String"
  tier        = "Standard"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
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
          measurement = ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system", "cpu_usage_iowait"]
          resources   = ["*"]
          totalcpu    = true
        }
        mem = { measurement = ["mem_used_percent", "mem_available", "mem_free"] }
        disk = {
          measurement              = ["used_percent", "inodes_free"]
          resources                = ["*"]
          ignore_file_system_types = ["sysfs", "devtmpfs", "overlay", "squashfs", "tracefs", "tmpfs"]
        }
        net = {
          measurement = ["bytes_sent", "bytes_recv", "packets_sent", "packets_recv"]
          resources   = ["*"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path                = "/var/lib/docker/containers/*/*-json.log"
              log_group_name           = "/ec2/llm-stack/docker"
              log_stream_name          = "{instance_id}-{container_id}"
              timestamp_format         = "%Y-%m-%dT%H:%M:%S.%fZ"
              multi_line_start_pattern = "^{"
            },
            {
              file_path        = "/var/log/syslog"
              log_group_name   = "/ec2/llm-stack/system"
              log_stream_name  = "{instance_id}-syslog"
              timestamp_format = "%b %d %H:%M:%S"
            }
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