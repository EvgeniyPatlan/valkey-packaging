packer {
  required_version = ">= 1.8.0"

  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  build_date = formatdate("YYYYMMDD-hhmm", timestamp())

  common_tags = {
    Product           = "Percona Valkey"
    ValkeyVersion     = var.valkey_version
    RepoChannel       = var.repo_channel
    BuildDate         = formatdate("YYYYMMDD-hhmm", timestamp())
    "iit-billing-tag" = var.billing_tag
  }

  billing_run_tags = {
    "iit-billing-tag" = var.billing_tag
  }
}

source "amazon-ebs" "slim_x86_64" {
  region                      = var.build_region
  instance_type               = var.instance_type_x86_64
  ssh_username                = "ec2-user"
  ssh_clear_authorized_keys   = true
  ami_name                    = "percona-valkey-${var.valkey_version}-slim-x86_64-${local.build_date}"
  ami_description             = "Percona Valkey ${var.valkey_version} on Amazon Linux 2023"
  ami_regions                 = var.ami_regions
  encrypt_boot                = false
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags            = merge(local.common_tags, { Variant = "slim", Architecture = "x86_64" })
  run_tags        = merge(local.billing_run_tags, { Name = "packer-valkey-slim-x86_64" })
  run_volume_tags = local.billing_run_tags
  snapshot_tags   = merge(local.common_tags, { Variant = "slim", Architecture = "x86_64" })
}

source "amazon-ebs" "slim_arm64" {
  region                      = var.build_region
  instance_type               = var.instance_type_arm64
  ssh_username                = "ec2-user"
  ssh_clear_authorized_keys   = true
  ami_name                    = "percona-valkey-${var.valkey_version}-slim-arm64-${local.build_date}"
  ami_description             = "Percona Valkey ${var.valkey_version} on Amazon Linux 2023"
  ami_regions                 = var.ami_regions
  encrypt_boot                = false
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags            = merge(local.common_tags, { Variant = "slim", Architecture = "arm64" })
  run_tags        = merge(local.billing_run_tags, { Name = "packer-valkey-slim-arm64" })
  run_volume_tags = local.billing_run_tags
  snapshot_tags   = merge(local.common_tags, { Variant = "slim", Architecture = "arm64" })
}

source "amazon-ebs" "bundle_x86_64" {
  region                      = var.build_region
  instance_type               = var.instance_type_x86_64
  ssh_username                = "ec2-user"
  ssh_clear_authorized_keys   = true
  ami_name                    = "percona-valkey-${var.valkey_version}-bundle-x86_64-${local.build_date}"
  ami_description             = "Percona Valkey ${var.valkey_version} with modules on Amazon Linux 2023"
  ami_regions                 = var.ami_regions
  encrypt_boot                = false
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags            = merge(local.common_tags, { Variant = "bundle", Architecture = "x86_64" })
  run_tags        = merge(local.billing_run_tags, { Name = "packer-valkey-bundle-x86_64" })
  run_volume_tags = local.billing_run_tags
  snapshot_tags   = merge(local.common_tags, { Variant = "bundle", Architecture = "x86_64" })
}

source "amazon-ebs" "bundle_arm64" {
  region                      = var.build_region
  instance_type               = var.instance_type_arm64
  ssh_username                = "ec2-user"
  ssh_clear_authorized_keys   = true
  ami_name                    = "percona-valkey-${var.valkey_version}-bundle-arm64-${local.build_date}"
  ami_description             = "Percona Valkey ${var.valkey_version} with modules on Amazon Linux 2023"
  ami_regions                 = var.ami_regions
  encrypt_boot                = false
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags            = merge(local.common_tags, { Variant = "bundle", Architecture = "arm64" })
  run_tags        = merge(local.billing_run_tags, { Name = "packer-valkey-bundle-arm64" })
  run_volume_tags = local.billing_run_tags
  snapshot_tags   = merge(local.common_tags, { Variant = "bundle", Architecture = "arm64" })
}

build {
  name    = "slim"
  sources = ["source.amazon-ebs.slim_x86_64", "source.amazon-ebs.slim_arm64"]

  provisioner "shell" {
    inline = [
      "sudo dnf -y install ansible-core tar gzip",
      # Amazon Linux 2023 ships no bats package. Install the pinned upstream
      # release under /opt so the whole tree can be removed before the snapshot.
      "curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v${var.bats_version}.tar.gz -o /tmp/bats.tar.gz",
      "tar -xzf /tmp/bats.tar.gz -C /tmp",
      "sudo /tmp/bats-core-${var.bats_version}/install.sh /opt/bats",
      "rm -rf /tmp/bats.tar.gz /tmp/bats-core-${var.bats_version}",
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "${path.root}/../ansible/valkey-ami.yml"
    playbook_dir  = "${path.root}/../ansible"
    extra_arguments = [
      "-e", "valkey_variant=slim",
      "-e", "valkey_version=${var.valkey_version}",
      "-e", "valkey_repo_channel=${var.repo_channel}",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../test/bats"
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "sudo VALKEY_VARIANT=slim VALKEY_VERSION=${var.valkey_version} /opt/bats/bin/bats /tmp/bats/*.bats",
      "rm -rf /tmp/bats",
      # Build-time only: neither belongs in a published image.
      "sudo rm -rf /opt/bats",
      "sudo dnf -y remove ansible-core",
      "sudo dnf clean all",
    ]
  }
}

build {
  name    = "bundle"
  sources = ["source.amazon-ebs.bundle_x86_64", "source.amazon-ebs.bundle_arm64"]

  provisioner "shell" {
    inline = [
      "sudo dnf -y install ansible-core tar gzip",
      "curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v${var.bats_version}.tar.gz -o /tmp/bats.tar.gz",
      "tar -xzf /tmp/bats.tar.gz -C /tmp",
      "sudo /tmp/bats-core-${var.bats_version}/install.sh /opt/bats",
      "rm -rf /tmp/bats.tar.gz /tmp/bats-core-${var.bats_version}",
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "${path.root}/../ansible/valkey-ami.yml"
    playbook_dir  = "${path.root}/../ansible"
    extra_arguments = [
      "-e", "valkey_variant=bundle",
      "-e", "valkey_version=${var.valkey_version}",
      "-e", "valkey_repo_channel=${var.repo_channel}",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../test/bats"
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "sudo VALKEY_VARIANT=bundle VALKEY_VERSION=${var.valkey_version} /opt/bats/bin/bats /tmp/bats/*.bats",
      "rm -rf /tmp/bats",
      "sudo rm -rf /opt/bats",
      "sudo dnf -y remove ansible-core",
      "sudo dnf clean all",
    ]
  }
}
