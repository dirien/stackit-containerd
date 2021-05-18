terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = ">=2.1.0"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">=1.42.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=2.59.0"
    }
  }
  backend "azurerm" {
    storage_account_name = "aebi"
    container_name       = "stackit-containerd-state"
    key                  = "stackit-containerd.tfstate"
  }
}

resource "openstack_compute_keypair_v2" "stackit-containerd-kp" {
  name       = "${var.stackit-containerd-name}-kp"
  public_key = file("${var.ssh_key_file}.pub")
}

resource "openstack_networking_network_v2" "stackit-containerd-net" {
  name           = "${var.stackit-containerd-name}-net"
  admin_state_up = "true"
}


resource "openstack_networking_subnet_v2" "stackit-containerd-snet" {
  name       = "${var.stackit-containerd-name}-snet"
  network_id = openstack_networking_network_v2.stackit-containerd-net.id
  cidr       = var.subnet-cidr
  ip_version = 4
  dns_nameservers = [
    "8.8.8.8",
  "8.8.4.4"]
}

resource "openstack_networking_router_v2" "stackit-containerd-router" {
  name                = "${var.stackit-containerd-name}-router"
  admin_state_up      = "true"
  external_network_id = data.openstack_networking_network_v2.floating.id
}

resource "openstack_networking_router_interface_v2" "stackit-containerd-ri" {
  router_id = openstack_networking_router_v2.stackit-containerd-router.id
  subnet_id = openstack_networking_subnet_v2.stackit-containerd-snet.id
}

resource "openstack_networking_secgroup_v2" "stackit-containerd-sg" {
  name        = "${var.stackit-containerd-name}-sec"
  description = "Security group for the Terraform nodes instances"
}

resource "openstack_networking_secgroup_rule_v2" "stackit-containerd-22-sgr" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.stackit-containerd-sg.id
}

resource "openstack_networking_secgroup_rule_v2" "stackit-containerd-443-sgr" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.stackit-containerd-sg.id
}

data "template_cloudinit_config" "ubuntu-config" {
  gzip          = true
  base64_encode = true

  # Main cloud-config configuration file.
  part {
    content_type = "text/cloud-config"
    content      = <<-EOF
      #cloud-config
      users:
        - default

      package_update: true

      packages:
        - apt-transport-https
        - ca-certificates
        - curl
        - gnupg-agent
        - software-properties-common
        - libseccomp2
        - uidmap
        - unzip
        - tar

      # Enable ipv4 forwarding, required on CIS hardened machines
      write_files:
        - path: /etc/sysctl.d/99-kubernetes-cri.conf
          content: |
            net.ipv4.conf.all.forwarding        =1
            net.bridge.bridge-nf-call-iptables  = 1
            net.ipv4.ip_forward                 = 1
            net.bridge.bridge-nf-call-ip6tables = 1


      runcmd:
        - sed -i '/^GRUB_CMDLINE_LINUX/ s/"$/systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
        - update-grub
      EOF
  }
}

resource "openstack_compute_instance_v2" "stackit-containerd-vm" {
  name        = "${var.stackit-containerd-name}-ubuntu"
  flavor_name = var.flavor
  key_pair    = openstack_compute_keypair_v2.stackit-containerd-kp.name
  security_groups = [
    "default",
    openstack_networking_secgroup_v2.stackit-containerd-sg.name
  ]

  user_data = data.template_cloudinit_config.ubuntu-config.rendered

  network {
    name = openstack_networking_network_v2.stackit-containerd-net.name
  }

  block_device {
    uuid                  = var.ubuntu-image-id
    source_type           = "image"
    boot_index            = 0
    destination_type      = "volume"
    volume_size           = 10
    delete_on_termination = true
  }
}

resource "openstack_networking_floatingip_v2" "stackit-containerd-fip" {
  pool  = var.pool
}

resource "openstack_compute_floatingip_associate_v2" "stackit-containerd-fipa" {
  instance_id = openstack_compute_instance_v2.stackit-containerd-vm.id
  floating_ip = openstack_networking_floatingip_v2.stackit-containerd-fip.address
}

output "stackit-containerd-private" {
  value       = openstack_compute_instance_v2.stackit-containerd-vm.access_ip_v4
  description = "The private ips of the nodes"
}

output "stackit-containerd-public" {
  value       = openstack_networking_floatingip_v2.stackit-containerd-fip.address
  description = "The public ips of the nodes"
}