
locals {
  tmp_dir = "${path.cwd}/.tmp"
  kube_config    = "${local.tmp_dir}/cluster/.kube"  
  cred_file_name = "rosa_admin_cred.json"
  cluster_info_file_name="cluster_info.json"    
}
data external dirs {
  program = ["bash", "${path.module}/scripts/create-dirs.sh"]

  query = {
    tmp_dir = "${local.tmp_dir}"
    kube_config = "${local.kube_config}" 
    #/kube_config"//"${local.tmp_dir}/.kube"    
  }
}

locals {
    create_user_script = <<-EOF
    #!/bin/bash
    export BIN_DIR=${local.bin_dir}
    export ROSA_TOKEN=${var.rosa_token}
    ${path.module}/scripts/create-rosa-user.sh ${var.cluster_name} ${var.region} ${data.external.dirs.result.tmp_dir} ${local.cred_file_name} ${local.cluster_info_file_name}
    EOF
    create_user_script_name = "create-user-script-${random_id.r.hex}.sh"
}


data "external" "write-apply-user-scripts" {
  program = ["bash", "-c", <<-EOF
    set -e
    echo '${local.create_user_script}' > ${local.create_user_script_name}
    echo '{ "create_user": "${local.create_user_script_name}" }'
  EOF
  ]

  depends_on = [
    module.setup_clis,    
    null_resource.create-rosa-cluster,
    null_resource.wait-for-cluster-ready,
    data.external.dirs
  ]
}

resource "null_resource" "create_rosa_user" {
   
  triggers = {
    tmp_dir  = data.external.dirs.result.tmp_dir
    cred_file_name    = local.cred_file_name
    cluster_info_file_name=local.cluster_info_file_name
    cluster_name = local.cluster_name    
    region          = var.region
    create_script_name  = data.external.write-apply-user-scripts.result.create_user
  }

  depends_on = [
    module.setup_clis,    
    null_resource.create-rosa-cluster,
    null_resource.wait-for-cluster-ready,
    data.external.dirs
  ]

  provisioner "local-exec" {
    when = create  
    command = "set -e; sh ${self.triggers.create_script_name}; rm ${self.triggers.create_script_name}"
  }
}

data external getClusterAdmin {
    depends_on = [
    module.setup_clis,      
    null_resource.create-rosa-cluster,
    null_resource.wait-for-cluster-ready,
    null_resource.create_rosa_user,
    data.external.dirs
  ]
  program = ["bash", "${path.module}/scripts/get-cluster-admin.sh"]       
  query = {
    bin_dir=local.bin_dir
    tmp_dir  = data.external.dirs.result.tmp_dir
    cred_file_name=local.cred_file_name
    cluster_info_file_name=local.cluster_info_file_name
  }
}

data external oc_login {
    depends_on = [
        module.setup_clis,      
        null_resource.create-rosa-cluster,
        null_resource.wait-for-cluster-ready,
        data.external.dirs,
        null_resource.create_rosa_user,
        data.external.getClusterAdmin
    ]
    
    program = ["bash", "${path.module}/scripts/oc-login.sh"]       
    query ={
        bin_dir=local.bin_dir
        serverUrl = data.external.getClusterAdmin.result.serverURL
        consoleUrl = data.external.getClusterAdmin.result.consoleUrl
        username = data.external.getClusterAdmin.result.adminUser
        password = data.external.getClusterAdmin.result.adminPwd
        clusterStatus=data.external.getClusterAdmin.result.clusterStatus        
        tmp_dir = data.external.dirs.result.tmp_dir
        kube_config = data.external.dirs.result.kube_config

    }    
 }
 
 resource null_resource print_oc_login_status {
  
  depends_on = [
    data.external.oc_login
  ]
  provisioner "local-exec" {
    command = "echo 'oc login message : ${data.external.oc_login.result.status}, clusterStatus: ${data.external.getClusterAdmin.result.clusterStatus}, loginStatus: ${data.external.oc_login.result.message}'"
  }
} 

# module "oclogin" {
#   source = "github.com/cloud-native-toolkit/terraform-ocp-login.git"

#   server_url =data.external.getClusterAdmin.result.serverURL
#   login_user = data.external.getClusterAdmin.result.adminUser
#   login_password = data.external.getClusterAdmin.result.adminPwd
#   login_token =""
#   skip = false
#   #ingress_subdomain = var.ingress_subdomain
#   #ca_cert = var.cluster_ca_cert
# }
