# Additional IAM policy for S3 backup access
resource "aws_iam_policy" "s3_backup" {
  name        = "llm-single-ec2-s3-backup"
  description = "Allow backup operations to S3"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_backup_attach" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.s3_backup.arn
}