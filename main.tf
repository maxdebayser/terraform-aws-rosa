locals {
  cluster_name = var.cluster_name != "" && var.cluster_name != null ? var.cluster_name : "${var.name_prefix}-cluster"
  bin_dir        = module.setup_clis.bin_dir
  compute_nodes = var.multi-zone-cluster ? (var.no_of_compute_nodes * 3) : var.no_of_compute_nodes
  compute_type = var.compute-machine-type != "" &&  var.compute-machine-type != null ? var.compute-machine-type : "m5.xlarge"
  join_subnets = var.existing_vpc ? (var.private-link ?  join(",",  var.private_subnet_ids ): join(",", var.public_subnet_ids, var.private_subnet_ids)) :  ""
  cmd_dry_run = var.dry_run ? " --dry-run" : ""
  multizone = var.multi-zone-cluster ? " --multi-az" : ""
  privatelink = var.private-link ? " --private-link" : ""
  sts = var.secure-token-service ? " --sts" : ""
  private = var.private ? " --private" : ""
  autoscaling = var.enable-autoscaling ? " --enable-autoscaling --min-replicas ${var.min-replicas} --max-replicas ${var.max-replicas}" : " --compute-nodes ${local.compute_nodes}"
  clsuter_cmd = " --cluster-name ${local.cluster_name} --region ${var.region} --version ${var.ocp_version} ${local.autoscaling} --compute-machine-type ${local.compute_type} --machine-cidr ${var.machine-cidr} --service-cidr ${var.service-cidr} --pod-cidr ${var.pod-cidr} --host-prefix ${var.host-prefix} --etcd-encryption ${local.multizone} ${local.privatelink} ${local.sts} ${local.cmd_dry_run} ${local.private} --yes"
  cluster_vpc_cmd = var.existing_vpc ? join(" ", [local.clsuter_cmd, " --subnet-ids ", local.join_subnets]) : ""
  create_clsuter_cmd = var.existing_vpc ? local.cluster_vpc_cmd : local.clsuter_cmd

  cluster_type          = "openshift"
  # value should be ocp4, ocp3, or kubernetes
  cluster_type_code     = "ocp4"
  cluster_type_tag      = "ocp"
  cluster_version       = "${var.ocp_version}_openshift"

}

module "setup_clis" {
  source = "github.com/cloud-native-toolkit/terraform-util-clis.git?ref=v1.16.4"

  clis   = ["jq", "rosa", "oc"]
}
resource null_resource print_names {
  provisioner "local-exec" {
    when    = create
    command = <<-EOF
      echo Cluster command : ${local.create_clsuter_cmd}
    EOF
  }
}

resource "random_id" "r" {
  byte_length = 4
}

locals {
    create_script = <<-EOF
    #!/bin/bash
    export BIN_DIR=${local.bin_dir}
    ${local.bin_dir}/rosa login --token=${var.rosa_token}
    ${local.bin_dir}/rosa verify quota --region=${var.region}
    ${local.bin_dir}/rosa init --region=${var.region}
    ${local.bin_dir}/rosa create cluster ${local.create_clsuter_cmd}


    if [ "${tostring(var.secure-token-service)}" = "true" ]; then
      echo "Setting up STS resources"

      cluster_id=$(${local.bin_dir}/rosa describe cluster -c ${var.cluster_name} -o json | ${local.bin_dir}/jq -r .id)

      ${local.bin_dir}/rosa create operator-roles --mode auto -c $cluster_id --yes
      ${local.bin_dir}/rosa create oidc-provider  --mode auto -c $cluster_id --yes
    fi
    EOF
    create_script_name = "create-script-${random_id.r.hex}.sh"

    destroy_script = <<-EOF
    #!/bin/bash
    export BIN_DIR=${local.bin_dir}
    ${local.bin_dir}/rosa login --token=${var.rosa_token}
    ${local.bin_dir}/rosa init --region=${var.region}

    cluster_id=$(${local.bin_dir}/rosa describe cluster -c ${var.cluster_name} -o json | ${local.bin_dir}/jq -r .id)

    ${path.module}/scripts/delete_cluster.sh ${var.cluster_name}  ${var.region} ${var.rosa_token} ${local.bin_dir} 
    
    if [ "${tostring(var.secure-token-service)}" = "true" ]; then
      echo "Tearing down STS resources"
      ${local.bin_dir}/rosa delete operator-roles --mode auto -c $cluster_id --yes
      ${local.bin_dir}/rosa delete oidc-provider  --mode auto -c $cluster_id --yes
    fi
    EOF
    destroy_script_name = "destroy-script-${random_id.r.hex}.sh"

    wait_script = <<-EOF
    #!/bin/bash
    export BIN_DIR=${local.bin_dir}
    export ROSA_TOKEN=${var.rosa_token}
    ${path.module}/scripts/wait-for-cluster-ready.sh ${local.cluster_name} ${var.region}
    EOF
    wait_script_name = "wait-script-${random_id.r.hex}.sh"
}


data "external" write_scripts {
  program = ["bash", "-c", <<-EOF
    set -e
    echo '${local.create_script}'  > ${local.create_script_name}
    echo '${local.wait_script}'    > ${local.wait_script_name}
    echo '${local.destroy_script}' > ${local.destroy_script_name}
    echo '{ "create": "${local.create_script_name}", "wait": "${local.wait_script_name}", "destroy": "${local.destroy_script_name}" }'
  EOF
  ]

  depends_on = [
    module.setup_clis,
    null_resource.print_names
  ]
}

resource "null_resource" "create-rosa-cluster" {
  triggers = {
    create_clsuter_cmd  = local.create_clsuter_cmd
    cluster_name        = local.cluster_name
    region              = var.region
    setup_sts           = tostring(var.secure-token-service)
    create_script_name  = data.external.write_scripts.result.create
    destroy_script_name = data.external.write_scripts.result.destroy
  }
  depends_on = [
    module.setup_clis,
    null_resource.print_names,
  ]

  provisioner "local-exec" {
    when    = create
    command = "set -e; sh ${self.triggers.create_script_name}; rm ${self.triggers.create_script_name}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "set -e; sh ${self.triggers.destroy_script_name}; rm ${self.triggers.destroy_script_name}"
  } 
}


resource null_resource wait-for-cluster-ready {
 depends_on = [null_resource.create-rosa-cluster]
  triggers = {
    wait_script_name  = data.external.write_scripts.result.wait
  }

  provisioner "local-exec" {
    when = create  
    command = "set -e; sh ${self.triggers.wait_script_name}; rm ${self.triggers.wait_script_name}"
  }

}
