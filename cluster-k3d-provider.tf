terraform {
  required_providers {
    k3d = {
      source = "moio/k3d"
      version = "0.0.12"
    }
  }
}

provider "k3d" {}

resource "k3d_cluster" "kubed" {
  name    = "kubed"
  servers = 1
  agents  = 2

  kube_api {
    host      = "k3s.arjf.dev"
    host_ip   = "192.168.1.1"
    host_port = 6550
  }

  image   = "rancher/k3s:v1.30.6-k3s1"
  network = "kube"
  # token   = "superSecretToken"

  /*
  volume {
    source      = "/my/host/path"
    destination = "/path/in/node"
    node_filters = [
      "server[0]",
      "agent[*]",
    ]
  }
  */

  port {
    host_port      = 80
    container_port = 80
    node_filters = [
      "loadbalancer",
    ]
  }

  port {
    host_port      = 443
    container_port = 443
    node_filters = [
      "loadbalancer",
    ]
  }

  port {
    host_port      = 8080
    container_port = 8080
    node_filters = [
      "loadbalancer",
    ]
  }

  /*
  label {
    key   = "foo"
    value = "bar"
    node_filters = [
      "agent[1]",
    ]
  }
  */

  /*
  env {
    key   = "bar"
    value = "baz"
    node_filters = [
      "server[0]",
    ]
  }
  */

  /*
  registries {
    create = {
      name      = "my-registry"
      host      = "my-registry.local"
      image     = "docker.io/some/registry"
      host_port = "5001"
    }
    use = [
      "k3d-myotherregistry:5000"
    ]
    config = <<EOF
mirrors:
  "my.company.registry":
    endpoint:
      - http://my.company.registry:5000
EOF
  }
  */

  k3d {
    disable_load_balancer = false
    disable_image_volume  = false
  }

  k3s {
    extra_args {
      arg          = "--tls-san=k3s.arjf.dev,192.168.1.1"
      node_filters = ["agent:*", "server:0"]
    }
  }

  kubeconfig {
    update_default_kubeconfig = true
    switch_current_context    = true
  }

  /*
  runtime {
    gpu_request = "all"
  }
  */
}